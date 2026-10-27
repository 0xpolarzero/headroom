#!/bin/sh
# Builds dist/Headroom.app from the Swift package (release, ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/Headroom"
app=dist/Headroom.app
version="${VERSION:-0.1.0}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Headroom"
# The Claude Code plugin that runs subagents on other accounts, a marketplace Claude Code reads in place.
cp -R ClaudePlugin "$app/Contents/Resources/ClaudePlugin"
rm -rf "$app/Contents/Resources/ClaudePlugin/headroom/tests" "$app/Contents/Resources/ClaudePlugin/headroom/.claude-plugin/types"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Headroom</string>
    <key>CFBundleIdentifier</key><string>dev.polarzero.headroom</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Headroom</string>
    <key>CFBundleDisplayName</key><string>Headroom</string>
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
