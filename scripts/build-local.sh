#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/.build/local"
APP_PATH="$OUTPUT_DIR/Codex Helper.app"
ARCHITECTURE="$(uname -m)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$OUTPUT_DIR/module-cache"
xcrun swiftc -warnings-as-errors -O -target "$ARCHITECTURE-apple-macosx13.0" \
  -module-cache-path "$OUTPUT_DIR/module-cache" "$ROOT"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework ServiceManagement -framework WidgetKit -framework UserNotifications \
  -o "$APP_PATH/Contents/MacOS/CodexHelper"
cp "$ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements "$ROOT/Resources/CodexHelper.entitlements" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
echo "$APP_PATH"
