#!/bin/bash
# uninstall.sh — Completely remove Sidecar from your system
#
# Usage:
#   chmod +x uninstall.sh
#   ./uninstall.sh
#
# What it removes:
#   - /Applications/Sidecar.app
#   - LaunchAgent (stops auto-start)
#   - Config and manifest data
#   - Logs
#
# What it does NOT remove:
#   - Migrated apps on your external drive
#   - Symlinks in /Applications (you'll need to manually restore those)

set -e

BUNDLE_ID="com.projectsidecar.app"
APP_PATH="/Applications/Sidecar.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
CONFIG_DIR="${HOME}/Library/Application Support/ProjectSidecar"
LOG_DIR="${HOME}/Library/Logs/ProjectSidecar"

echo "=== Project Sidecar Uninstaller ==="
echo ""

# Check for active migrations
MANIFEST="${CONFIG_DIR}/manifest.json"
if [ -f "$MANIFEST" ]; then
    ACTIVE_COUNT=$(python3 -c "import json; data=json.load(open('$MANIFEST')); print(len([r for r in data if r.get('status')=='active']))" 2>/dev/null || echo "unknown")
    if [ "$ACTIVE_COUNT" != "0" ] && [ "$ACTIVE_COUNT" != "unknown" ]; then
        echo "⚠️  WARNING: You have ${ACTIVE_COUNT} active migration(s)."
        echo "   Symlinks in /Applications point to your external drive."
        echo "   After uninstalling Sidecar, those symlinks will still work"
        echo "   as long as the external drive is connected."
        echo ""
        echo "   To restore apps to the internal drive, manually move them"
        echo "   back before uninstalling, or keep the manifest for reference:"
        echo "   ${MANIFEST}"
        echo ""
    fi
fi

read -p "Are you sure you want to uninstall Sidecar? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

# Stop and remove LaunchAgent
if [ -f "$LAUNCH_AGENT" ]; then
    echo "Removing LaunchAgent..."
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
fi

# Remove app
if [ -d "$APP_PATH" ]; then
    echo "Removing Sidecar.app..."
    rm -rf "$APP_PATH"
fi

# Remove config (ask first since it has migration data)
if [ -d "$CONFIG_DIR" ]; then
    read -p "Remove configuration and migration manifest? (y/n): " REMOVE_CONFIG
    if [ "$REMOVE_CONFIG" = "y" ] || [ "$REMOVE_CONFIG" = "Y" ]; then
        rm -rf "$CONFIG_DIR"
        echo "Removed config directory."
    else
        echo "Kept: ${CONFIG_DIR}"
    fi
fi

# Remove logs
if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
    echo "Removed logs."
fi

echo ""
echo "✅ Sidecar has been uninstalled."
echo ""
echo "Note: Any symlinks created by Sidecar in /Applications are still in place."
echo "They will continue to work as long as your external drive is connected."
echo "To find them: ls -la /Applications/ | grep '\\->'"
