#!/bin/bash
# install.sh — Install Sidecar.app and optionally set up Launch at Login
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# What it does:
#   1. Builds the .app bundle (calls build-app.sh)
#   2. Copies Sidecar.app to /Applications
#   3. Optionally creates a LaunchAgent for auto-start at login

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Sidecar"
BUNDLE_ID="com.projectsidecar.app"
APP_SOURCE="${SCRIPT_DIR}/build/${APP_NAME}.app"
APP_DEST="/Applications/${APP_NAME}.app"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${BUNDLE_ID}.plist"

# Step 1: Build
echo "=== Step 1: Building Sidecar ==="
cd "${SCRIPT_DIR}"
chmod +x build-app.sh
./build-app.sh

# Step 2: Install to /Applications
echo ""
echo "=== Step 2: Installing to /Applications ==="
if [ -d "${APP_DEST}" ]; then
    echo "Removing previous installation..."
    rm -rf "${APP_DEST}"
fi
cp -r "${APP_SOURCE}" "${APP_DEST}"
echo "✅ Installed: ${APP_DEST}"

# Step 3: Launch at Login
echo ""
echo "=== Step 3: Launch at Login ==="
read -p "Start Sidecar automatically at login? (y/n): " AUTOSTART

if [ "$AUTOSTART" = "y" ] || [ "$AUTOSTART" = "Y" ]; then
    mkdir -p "${LAUNCH_AGENT_DIR}"

    cat > "${LAUNCH_AGENT_PLIST}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/ProjectSidecar/sidecar.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/ProjectSidecar/sidecar-error.log</string>
</dict>
</plist>
EOF

    # Create log directory
    mkdir -p "${HOME}/Library/Logs/ProjectSidecar"

    # Load the agent
    launchctl unload "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
    launchctl load "${LAUNCH_AGENT_PLIST}"

    echo "✅ LaunchAgent installed: ${LAUNCH_AGENT_PLIST}"
    echo "   Sidecar will start automatically at login."
    echo "   Logs: ~/Library/Logs/ProjectSidecar/"
else
    # Remove LaunchAgent if it exists
    if [ -f "${LAUNCH_AGENT_PLIST}" ]; then
        launchctl unload "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
        rm -f "${LAUNCH_AGENT_PLIST}"
        echo "Removed existing LaunchAgent."
    fi
    echo "Skipped. Run Sidecar manually: open /Applications/Sidecar.app"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "⚠️  IMPORTANT: Grant Full Disk Access to Sidecar"
echo "   System Settings → Privacy & Security → Full Disk Access"
echo "   Click + → navigate to /Applications/Sidecar.app → Open"
echo ""
echo "To start now:"
echo "   open /Applications/Sidecar.app"
