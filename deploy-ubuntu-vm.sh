#!/bin/bash
set -euo pipefail

# ============================================
# Configuration Variables - Modify as needed
# ============================================
RESOURCE_GROUP="OpenClawOnAzure"
VM_NAME="ubuntu-openclaw-vm"
LOCATION="westeurope"
ADMIN_USERNAME="innoday_xebia_claw_team"
VM_SIZE="Standard_D4s_v5"  # 4GB memory
NSG_NAME="${VM_NAME}NSG"

# Allowed outbound destination IPs/CIDRs (adjust to your needs)
ALLOWED_OUTBOUND_IPS=("AzureCloud" "1.2.3.4/32")

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
# Check if resource group exists, create if not
# ============================================
echo "Checking resource group $RESOURCE_GROUP..."
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating resource group $RESOURCE_GROUP..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
else
    echo "Resource group $RESOURCE_GROUP already exists."
fi

# ============================================
# Create Ubuntu Virtual Machine (idempotent)
# ============================================
echo "Checking if VM $VM_NAME exists..."
if ! az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" &>/dev/null; then
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
else
    echo "VM $VM_NAME already exists, skipping creation."
fi

# ============================================
# Get VM Public IP
# ============================================
echo "Getting VM public IP..."
PUBLIC_IP=$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)
echo "VM Public IP: $PUBLIC_IP"

# ============================================
# Configure NSG outbound rules (idempotent)
# ============================================
echo "Configuring NSG outbound rules on $NSG_NAME..."

# Allow DNS outbound (required for apt, npm, etc.)
upsert_nsg_rule "AllowDNSOutbound" \
    --priority 100 --direction Outbound --access Allow \
    --protocol "*" --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 53

# Allow HTTPS outbound (required for package downloads)
upsert_nsg_rule "AllowHTTPSOutbound" \
    --priority 200 --direction Outbound --access Allow \
    --protocol Tcp --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 443

# Allow HTTP outbound (some repos use HTTP)
upsert_nsg_rule "AllowHTTPOutbound" \
    --priority 300 --direction Outbound --access Allow \
    --protocol Tcp --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges 80

# Allow specific outbound IPs (custom destinations)
priority=400
for ip in "${ALLOWED_OUTBOUND_IPS[@]}"; do
    rule_name="AllowOutbound_$(echo "$ip" | tr './' '_')"
    upsert_nsg_rule "$rule_name" \
        --priority $priority --direction Outbound --access Allow \
        --protocol "*" --source-address-prefixes "*" \
        --destination-address-prefixes "$ip" --destination-port-ranges "*"
    priority=$((priority + 10))
done

# Deny all other outbound traffic (low priority catch-all)
upsert_nsg_rule "DenyAllOtherOutbound" \
    --priority 4000 --direction Outbound --access Deny \
    --protocol "*" --source-address-prefixes "*" \
    --destination-address-prefixes "*" --destination-port-ranges "*"

echo "NSG outbound rules configured."

# ============================================
# Install Node.js and openclaw using az vm run-command
# ============================================
echo "Installing software using az vm run-command..."

# Step 1: Update system packages
echo "Step 1/4: Updating system packages..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "sudo apt-get update && sudo apt-get upgrade -y"

# Step 2: Install dependencies (git, curl, build-essential)
echo "Step 2/4: Installing dependencies..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "sudo apt-get install -y git curl build-essential cmake"

# Step 3: Install Node.js LTS via NodeSource (idempotent — skips if already installed)
echo "Step 3/4: Installing Node.js LTS..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
else
    echo 'Node.js already installed: '\$(node --version)
fi
"

# Step 4: Install openclaw globally (idempotent — skips if already installed)
echo "Step 4/4: Installing openclaw..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "
if ! npm list -g openclaw &>/dev/null; then
    sudo npm install -g openclaw
else
    echo 'openclaw already installed'
fi
"

# Verify installation
echo "Verifying installation..."
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "echo 'Node.js version:' && node --version && echo 'npm version:' && npm --version && echo 'openclaw:' && npm list -g openclaw"

echo "============================================"
echo "Deployment completed!"
echo "============================================"
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Name: $VM_NAME"
echo "Public IP: $PUBLIC_IP"
echo "Admin Username: $ADMIN_USERNAME"
echo "VM Size: $VM_SIZE (4GB memory)"
echo "NSG: $NSG_NAME"
echo ""
echo "Connect via SSH: ssh $ADMIN_USERNAME@$PUBLIC_IP"
echo "============================================"
