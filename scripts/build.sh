#!/bin/bash
# Builds build/Claude Island.app (ad-hoc signed unless ISLAND_SIGN_IDENTITY is set).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Claude Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Sources/main.swift Sources/Island.swift Sources/Overview.swift Sources/Ambient.swift Sources/Alerts.swift \
  Sources/Tasks.swift Sources/Usage.swift Sources/ZedJump.swift -o "$APP/Contents/MacOS/claude-island"
cp bundle/Info.plist "$APP/Contents/Info.plist"
tmp="$(mktemp -d)/AppIcon.iconset"
swift bundle/icon.swift "$tmp" && iconutil -c icns "$tmp" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${ISLAND_SIGN_IDENTITY:--}" --identifier dev.claude-island "$APP" 2>&1 | grep -v "replacing existing signature" || true
swiftc -O Sources/GlassToast.swift -o "$PWD/build/glass-toast"   # fallback toast when the island is not running
echo "built: $APP"
