#!/bin/bash
# build-app.sh — Build Project Sidecar as a native macOS .app bundle
#
# Usage:
#   chmod +x build-app.sh
#   ./build-app.sh
#
# Output: build/Sidecar.app (double-click to run, drag to /Applications)

set -e

APP_NAME="Sidecar"
BUNDLE_ID="com.projectsidecar.app"
VERSION="0.1.0"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "🔨 Building release binary..."
swift build -c release

BINARY=$(swift build -c release --show-bin-path)/ProjectSidecar

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed — binary not found."
    exit 1
fi

echo "📦 Creating ${APP_NAME}.app bundle..."

# Clean previous build
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy binary
cp "${BINARY}" "${MACOS}/${APP_NAME}"

# Create Info.plist
cat > "${CONTENTS}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Project Sidecar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Sidecar needs permission to move applications and create symbolic links.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

echo "✅ Built: ${APP_DIR}"
echo ""
echo "To install:"
echo "  cp -r ${APP_DIR} /Applications/"
echo ""
echo "To run now:"
echo "  open ${APP_DIR}"
echo ""
echo "NOTE: You'll need to grant Full Disk Access to Sidecar.app"
echo "  System Settings → Privacy & Security → Full Disk Access → + → select Sidecar.app"
