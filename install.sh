#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/ClaudeDashboard.app"
SRC="$(cd "$(dirname "$0")" && pwd)/claude-dashboard.swift"

echo "Building Claude Dashboard..."
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/ClaudeDashboard" "$SRC"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeDashboard</string>
    <key>CFBundleIdentifier</key>
    <string>com.cvl.claude-dashboard</string>
    <key>CFBundleName</key>
    <string>Claude Dashboard</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

echo "Installed to $APP"
echo "Run: open /Applications/ClaudeDashboard.app"
