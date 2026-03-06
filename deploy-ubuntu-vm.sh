#!/bin/bash
set -euo pipefail

# ============================================
# Configuration Variables - Modify as needed
# ============================================
RESOURCE_GROUP="OpenClawOnAzure"
VM_NAME="ubuntu-openclaw-vm"
LOCATION="westeurope"
ADMIN_USERNAME="innoday_xebia_claw_team"
VM_SIZE="Standard_D4s_v6"  # 4 vCPUs, 16 GB RAM
NSG_NAME="${VM_NAME}NSG"

# Your current public IP — only this IP can SSH into the VM.
# Auto-detected; override manually if needed.
MY_IP=$(curl -s https://ifconfig.me)/32

# ============================================
# Helper: create or update an NSG rule idempotently
# ============================================
upsert_nsg_rule() {
    local rule_name="$1"; shift
    if az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$rule_name" &>/dev/null; then
        echo "  Updating existing NSG rule: $rule_name"
        az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$rule_name" "$@"
    else
        echo "  Creating NSG rule: $rule_name"
        az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$rule_name" "$@"
    fi
}

# ============================================
# 1. Resource Group
# ============================================
echo "Checking resource group $RESOURCE_GROUP..."
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating resource group $RESOURCE_GROUP..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
else
    echo "Resource group $RESOURCE_GROUP already exists."
fi

# ============================================
# 2. Delete existing VM (wipe clean)
# ============================================
echo "Checking if VM $VM_NAME exists..."
if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" &>/dev/null; then
    echo "Deleting existing VM $VM_NAME and all associated resources..."
    az vm delete -g "$RESOURCE_GROUP" -n "$VM_NAME" --yes --force-deletion true
    # Clean up leftover resources (NIC, disk, public IP, NSG)
    for nic in $(az network nic list -g "$RESOURCE_GROUP" --query "[?contains(name,'$VM_NAME')].name" -o tsv); do
        echo "  Deleting NIC: $nic"
        az network nic delete -g "$RESOURCE_GROUP" -n "$nic" || true
    done
    for disk in $(az disk list -g "$RESOURCE_GROUP" --query "[?contains(name,'$VM_NAME')].name" -o tsv); do
        echo "  Deleting disk: $disk"
        az disk delete -g "$RESOURCE_GROUP" -n "$disk" --yes || true
    done
    for pip in $(az network public-ip list -g "$RESOURCE_GROUP" --query "[?contains(name,'$VM_NAME')].name" -o tsv); do
        echo "  Deleting public IP: $pip"
        az network public-ip delete -g "$RESOURCE_GROUP" -n "$pip" || true
    done
    for nsg in $(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name,'$VM_NAME')].name" -o tsv); do
        echo "  Deleting NSG: $nsg"
        az network nsg delete -g "$RESOURCE_GROUP" -n "$nsg" || true
    done
    echo "Old VM resources cleaned up."
fi

# ============================================
# 3. Create fresh Ubuntu VM
# ============================================
echo "Creating Ubuntu VM..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image Ubuntu2404 \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --nsg-rule SSH
echo "VM created successfully!"

# ============================================
# 4. Get VM Public IP
# ============================================
echo "Getting VM public IP..."
PUBLIC_IP=$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)
echo "VM Public IP: $PUBLIC_IP"

# ============================================
# 5. Configure NSG rules
# ============================================
echo "Configuring NSG rules on $NSG_NAME..."

# --- Inbound ---
# SSH from your IP only (replace the default allow-all SSH rule)
upsert_nsg_rule "default-allow-ssh" \
    --priority 1000 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$MY_IP" \
    --destination-address-prefixes "*" --destination-port-ranges 22

# No inbound rule for 18789 — dashboard is accessed via SSH tunnel only.

# --- Outbound ---
# Allow DNS (required for apt, Docker Hub, etc.)
upsert_nsg_rule "AllowDNSOutbound" \
    --priority 100 --direction Outbound --access Allow \
    --protocol "*" --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 53

# Allow HTTPS (Docker Hub, GitHub, npm, etc.)
upsert_nsg_rule "AllowHTTPSOutbound" \
    --priority 200 --direction Outbound --access Allow \
    --protocol Tcp --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 443

# Allow HTTP (some package repos)
upsert_nsg_rule "AllowHTTPOutbound" \
    --priority 300 --direction Outbound --access Allow \
    --protocol Tcp --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 80

# Deny all other outbound
upsert_nsg_rule "DenyAllOtherOutbound" \
    --priority 4000 --direction Outbound --access Deny \
    --protocol "*" --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges "*"

echo "NSG rules configured."

# ============================================
# 6. Install Docker on the VM
# ============================================
echo "Installing Docker..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "
export DEBIAN_FRONTEND=noninteractive
set -eu

# Install Docker prerequisites
apt-get update
apt-get install -y ca-certificates curl gnupg

# Add Docker GPG key and repo
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list

# Install Docker Engine + Compose plugin
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add admin user to docker group (no sudo needed for docker commands)
usermod -aG docker $ADMIN_USERNAME

systemctl enable docker
systemctl start docker

echo 'Docker installed:'
docker --version
docker compose version
"
echo "Docker installed."

# ============================================
# 7. Upload project files and build/start container
# ============================================
echo "Uploading project files to VM..."
REMOTE_DIR="/home/$ADMIN_USERNAME/openclaw"

# Create project directory on VM
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "
mkdir -p $REMOTE_DIR
chown $ADMIN_USERNAME:$ADMIN_USERNAME $REMOTE_DIR
"

# Copy files via SSH (wait for SSH to be ready)
echo "Waiting for SSH to be ready..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USERNAME@$PUBLIC_IP" "echo ok" &>/dev/null; then
        break
    fi
    echo "  Waiting for SSH... ($i/30)"
    sleep 10
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scp -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR/entrypoint.sh" \
    "$SCRIPT_DIR/docker-compose.yml" \
    "$ADMIN_USERNAME@$PUBLIC_IP:$REMOTE_DIR/"

echo "Files uploaded. Building and starting container..."

# Build image and start container
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "
set -eu
cd $REMOTE_DIR

# Build the custom image
docker compose build --no-cache

# Start the container
docker compose up -d

# Wait for gateway to start
echo 'Waiting for gateway to start...'
for i in \$(seq 1 30); do
    if docker compose logs 2>&1 | grep -q 'listening on'; then
        echo 'Gateway is up!'
        break
    fi
    sleep 2
done

echo '=== Container status ==='
docker compose ps
echo '=== Recent logs ==='
docker compose logs --tail 20
"

echo ""
echo "============================================"
echo "Deployment completed!"
echo "============================================"
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Name:        $VM_NAME"
echo "Public IP:      $PUBLIC_IP"
echo "Admin User:     $ADMIN_USERNAME"
echo "VM Size:        $VM_SIZE"
echo ""
echo "Dashboard is NOT exposed publicly."
echo "Access via SSH tunnel:"
echo "  ssh -L 18789:127.0.0.1:18789 $ADMIN_USERNAME@$PUBLIC_IP"
echo "  Then open: http://localhost:18789"
echo ""
echo "Post-deploy: run 'openclaw configure' inside the container"
echo "to set up GitHub Copilot auth and model selection:"
echo "  ssh $ADMIN_USERNAME@$PUBLIC_IP"
echo "  docker exec -it openclaw-gateway openclaw configure"
echo "============================================"
