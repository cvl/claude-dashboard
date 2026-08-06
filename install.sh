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

# Build pty-proxy
PTY_SRC="$(cd "$(dirname "$0")" && pwd)/pty-proxy.c"
PTY_DST="/usr/local/bin/pty-proxy"
cc -O2 -o /tmp/pty-proxy "$PTY_SRC" -lutil
cp /tmp/pty-proxy "$PTY_DST" 2>/dev/null || sudo cp /tmp/pty-proxy "$PTY_DST"
chmod +x "$PTY_DST"
rm /tmp/pty-proxy

# Install cdash CLI
CLI_SRC="$(cd "$(dirname "$0")" && pwd)/cdash"
CLI_DST="/usr/local/bin/cdash"
cp "$CLI_SRC" "$CLI_DST" 2>/dev/null || sudo cp "$CLI_SRC" "$CLI_DST"
chmod +x "$CLI_DST"
# Keep claudedashboard as alias for backward compat
ln -sf "$CLI_DST" /usr/local/bin/claudedashboard 2>/dev/null || sudo ln -sf "$CLI_DST" /usr/local/bin/claudedashboard

echo "Installed to $APP"
echo "CLI: cdash <name> | cdash claude ... | cdash codex ..."
echo "Run: open /Applications/ClaudeDashboard.app"
