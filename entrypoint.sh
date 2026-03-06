#!/bin/bash
set -e

# ============================================
# Fix volume permissions — Docker named volumes
# are created as root; openclaw runs as node.
# ============================================
if [ "$(id -u)" = "0" ]; then
    chown -R node:node /home/node/.openclaw 2>/dev/null || true
fi

# ============================================
# Clean up Chrome singleton lock files left over
# from previous container runs — prevents
# "SingletonLock" errors on container recreate.
# ============================================
CHROME_PROFILE_DIR="/home/node/.config/google-chrome"
if [ -d "$CHROME_PROFILE_DIR" ]; then
    rm -f "$CHROME_PROFILE_DIR/SingletonLock" \
          "$CHROME_PROFILE_DIR/SingletonSocket" \
          "$CHROME_PROFILE_DIR/SingletonCookie"
    echo "[entrypoint] Cleaned Chrome singleton locks"
fi

# ============================================
# Kill any zombie Chrome processes holding the
# CDP port from a previous unclean shutdown.
# ============================================
pkill -9 -f "google-chrome|chromium" 2>/dev/null || true
echo "[entrypoint] Cleaned up stale Chrome processes"

# ============================================
# Drop to node user and start the gateway
# ============================================
if [ $# -eq 0 ]; then
    exec gosu node docker-entrypoint.sh node openclaw.mjs gateway --allow-unconfigured
else
    exec gosu node docker-entrypoint.sh "$@"
fi
