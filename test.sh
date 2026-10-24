#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"
BUILD_DIR="$ROOT/.build/tests"
ARCHITECTURE="$(uname -m)"
mkdir -p "$BUILD_DIR/module-cache"
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement -framework WidgetKit -framework UserNotifications)
COMMON=(-warnings-as-errors -target "$ARCHITECTURE-apple-macosx13.0" -module-cache-path "$BUILD_DIR/module-cache")
SOURCES=("$ROOT"/Sources/*.swift)

xcrun swiftc "${COMMON[@]}" "${SOURCES[@]}" "${FRAMEWORKS[@]}" -o "$BUILD_DIR/CodexHelper"
CODEX_HELPER_DISABLE_ACCESSIBILITY_PROMPTS=1 "$BUILD_DIR/CodexHelper" --self-test

LIBRARY_SOURCES=()
for source in "${SOURCES[@]}"; do
  [[ "${source:t}" == main.swift ]] || LIBRARY_SOURCES+=("$source")
done
xcrun swiftc "${COMMON[@]}" "${LIBRARY_SOURCES[@]}" "$ROOT/Tests/Safety/main.swift" "${FRAMEWORKS[@]}" -o "$BUILD_DIR/SafetyTests"
CODEX_HELPER_DISABLE_ACCESSIBILITY_PROMPTS=1 "$BUILD_DIR/SafetyTests"
xcrun swiftc "${COMMON[@]}" "$ROOT/Sources/ResetNotices.swift" "$ROOT/Sources/Config.swift" "$ROOT/Tests/ResetNotices/main.swift" "${FRAMEWORKS[@]}" -o "$BUILD_DIR/ResetNoticeTests"
"$BUILD_DIR/ResetNoticeTests"
xcrun swiftc "${COMMON[@]}" "$ROOT/Sources/ResetNotices.swift" "$ROOT/Sources/Config.swift" "$ROOT/Tests/Networking/main.swift" "${FRAMEWORKS[@]}" -o "$BUILD_DIR/NetworkingTests"
"$BUILD_DIR/NetworkingTests"
xcrun swiftc "${COMMON[@]}" -typecheck "$ROOT/WidgetExtension/CodexHelperWidget.swift" "$ROOT/Sources/WidgetSnapshot.swift" -framework SwiftUI -framework WidgetKit

if [[ "$(xcode-select -p)" == *.app/Contents/Developer ]]; then
  xcodebuild -quiet -project "$ROOT/CodexHelper.xcodeproj" -scheme CodexHelper \
    -configuration Debug -derivedDataPath "$BUILD_DIR/xcode" CODE_SIGNING_ALLOWED=NO build
else
  echo "SKIP: full app + Widget build requires Xcode; Swift checks passed."
fi
plutil -lint "$ROOT/CodexHelper.xcodeproj/project.pbxproj" "$ROOT/Resources/Info.plist" \
  "$ROOT/Resources/CodexHelper.entitlements" "$ROOT/WidgetExtension/Info.plist" \
  "$ROOT/WidgetExtension/CodexHelperWidget.entitlements"
ruby -rjson -e 'config = JSON.parse(File.read(ARGV.fetch(0))); abort "unsafe defaults" unless config["autoRetryEnabled"] == false && config["automaticUpdates"] == false' "$ROOT/Resources/config.json"
zsh -n "$ROOT"/*.sh "$ROOT"/scripts/*.sh
