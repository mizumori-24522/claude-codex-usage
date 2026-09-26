#!/bin/bash
# Builds Claude & Codex Usage with the Command Line Tools only (no Xcode needed).
#   ./build.sh            build into ./build
#   ./build.sh install    build, copy to ~/Applications and (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeCodexUsage.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/ClaudeCodexUsage"

cp Resources/Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/ClaudeCodexUsage" --icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/ClaudeCodexUsage.app"
  pkill -x ClaudeCodexUsage 2>/dev/null && sleep 0.5 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "installed $DEST"
fi
