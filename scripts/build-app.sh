#!/usr/bin/env bash
# Builds "build/CT Viewer.app" from the Swift package (needs only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds for Apple Silicon and Intel (needs full Xcode, as on CI).
if [ "${UNIVERSAL:-0}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/CTViewer
else
    swift build -c release
    BIN=.build/release/CTViewer
fi

APP="build/CT Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CTViewer"

# Regenerate with: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CT Viewer</string>
    <key>CFBundleDisplayName</key><string>CT Viewer</string>
    <key>CFBundleIdentifier</key><string>io.github.gamgee.dicom-viewer</string>
    <key>CFBundleExecutable</key><string>CTViewer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.medical</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>DICOM Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>DICOM Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>CFBundleTypeExtensions</key><array><string>dcm</string><string>dicom</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Disc Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key><array><string>iso</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
