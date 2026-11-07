#!/bin/bash
# Installs Claude Island for the current user:
#   build -> ~/Applications/Claude Island.app, hooks -> ~/.claude/hooks, queue helper -> ~/.claude/island,
#   LaunchAgent so it starts at login. It does NOT edit your Claude Code settings: merge hooks/settings-snippet.json yourself.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

APP_DIR="$HOME/Applications"
mkdir -p "$APP_DIR" "$HOME/.claude/hooks" "$HOME/.claude/island" "$HOME/.claude/notifier"
rm -rf "$APP_DIR/Claude Island.app"
cp -R "build/Claude Island.app" "$APP_DIR/"
cp hooks/*.sh hooks/stop.py "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/"*.sh
cp hooks/taskqueue.py "$HOME/.claude/island/"
cp hooks/detail.py "$HOME/.claude/notifier/"
cp build/glass-toast "$HOME/.claude/notifier/"

PLIST="$HOME/Library/LaunchAgents/dev.claude-island.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.claude-island</string>
  <key>ProgramArguments</key><array><string>$APP_DIR/Claude Island.app/Contents/MacOS/claude-island</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/dev.claude-island" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo
echo "Claude Island is running. Last step: merge hooks/settings-snippet.json into ~/.claude/settings.json"
echo "(your Claude Code settings are never touched by this script)."
