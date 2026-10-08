#!/bin/zsh
# Builds build/DoResearch.app. Uses swiftc directly so it works with the Command Line Tools alone.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DoResearch.app
CONFIG=${1:-release}
FLAGS=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -lsqlite3)
[[ "$CONFIG" == "release" ]] && FLAGS+=(-O) || FLAGS+=(-Onone -g)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling ($CONFIG)…"
swiftc "${FLAGS[@]}" $(find Sources -name '*.swift') -o "$APP/Contents/MacOS/DoResearch"

echo "Rendering icon…"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DoResearch</string>
    <key>CFBundleDisplayName</key><string>DoResearch</string>
    <key>CFBundleIdentifier</key><string>com.kr8u7k.DoResearch</string>
    <key>CFBundleExecutable</key><string>DoResearch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.kr8u7k.doresearch.items</string>
            <key>UTTypeDescription</key><string>DoResearch Items</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
