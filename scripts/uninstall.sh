#!/bin/bash
# Removes the app and LaunchAgent. Hooks in ~/.claude/hooks are left alone: remove them from your settings first.
set -euo pipefail
launchctl bootout "gui/$(id -u)/dev.claude-island" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/dev.claude-island.plist"
rm -rf "$HOME/Applications/Claude Island.app"
echo "removed. State files remain in ~/.claude/island and ~/.claude/notifier (delete them if you like)."
