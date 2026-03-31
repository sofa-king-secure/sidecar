#!/bin/bash
# build-app.sh — Build Project Sidecar as a native macOS .app bundle
#
# Usage:
#   chmod +x build-app.sh
#   ./build-app.sh

set -e

APP_NAME="Sidecar"
BUNDLE_ID="com.projectsidecar.app"
VERSION="0.3.0"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SOURCE="${SCRIPT_DIR}/Resources/AppIcon.png"

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

# Create app icon from PNG if source exists
if [ -f "${ICON_SOURCE}" ]; then
    echo "🎨 Creating app icon..."
    ICONSET="${BUILD_DIR}/AppIcon.iconset"
    rm -rf "${ICONSET}"
    mkdir -p "${ICONSET}"

    # Generate all required icon sizes
    sips -z 16 16     "${ICON_SOURCE}" --out "${ICONSET}/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET}/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET}/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     "${ICON_SOURCE}" --out "${ICONSET}/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   "${ICON_SOURCE}" --out "${ICONSET}/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET}/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET}/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET}/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET}/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET}/icon_512x512@2x.png" > /dev/null 2>&1

    # Convert to .icns
    iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns"
    rm -rf "${ICONSET}"

    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
else
    echo "⚠️  No icon source found at Resources/AppIcon.png — skipping icon."
    ICON_KEY=""
fi

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
${ICON_KEY}
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
