#!/bin/sh
# Builds dist/lastdrop.app from the Swift package (release, ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds for Apple silicon and Intel (needs Xcode).
archs=""
[ "${UNIVERSAL:-}" = 1 ] && archs="--arch arm64 --arch x86_64"
swift build -c release $archs
bin="$(swift build -c release $archs --show-bin-path)/lastdrop"
app=dist/lastdrop.app
version="${VERSION:-0.1.0}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/lastdrop"
# The Claude Code plugin that runs subagents on other accounts, a marketplace Claude Code reads in place.
cp -R ClaudePlugin "$app/Contents/Resources/ClaudePlugin"
# The app icon, drawn by the app itself.
iconset="$(mktemp -d)/AppIcon.iconset"
"$bin" --app-icon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$app/Contents/Resources/ClaudePlugin/lastdrop/tests" "$app/Contents/Resources/ClaudePlugin/lastdrop/.claude-plugin/types"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>lastdrop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.amontlabs.lastdrop</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>lastdrop</string>
    <key>CFBundleDisplayName</key><string>lastdrop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
codesign --verify "$app"
echo "Built $app"
