FROM alpine/openclaw:latest

USER root

# Install Google Chrome (stable) for headless browser automation
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg \
        ca-certificates \
        fonts-liberation \
        gosu \
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libcups2 \
        libdbus-1-3 \
        libdrm2 \
        libgbm1 \
        libgtk-3-0 \
        libnspr4 \
        libnss3 \
        libx11-xcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxrandr2 \
        xdg-utils && \
    wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    apt-get install -y /tmp/chrome.deb || true && \
    rm -f /tmp/chrome.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Pre-create the data directory with correct ownership
RUN mkdir -p /home/node/.openclaw && chown -R node:node /home/node/.openclaw

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run entrypoint as root — it fixes volume perms then drops to node via gosu
ENTRYPOINT ["/entrypoint.sh"]
