#!/bin/bash
# Writes per-session state for the Claude menu-bar monitor AND renames the
# owning terminal tab/window to reflect the session state.
# Usage: session-state.sh <status>   (status: waiting | working | end)
# Reads hook JSON on stdin; extracts session_id + cwd.

status="${1:-waiting}"
dir="$HOME/.claude/session-state"
mkdir -p "$dir"


payload="$(cat)"
sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -z "$sid" ] && sid="unknown"

f="$dir/$sid.json"

# you answered (or the session ended): the session's toast is no longer relevant
if [ "$status" = "working" ] || [ "$status" = "end" ]; then
  tp="$HOME/.claude/notifier/sessions/$sid"
  [ -f "$tp" ] && kill "$(cat "$tp")" 2>/dev/null
fi

# Find the controlling tty by walking up the process tree. The hook itself is
# detached (tty "??"), but its ancestors (claude -> login shell) own a real tty.
find_tty() {
  local pid=$$ depth=0 t
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 12 ]; do
    t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$t" ] && [ "$t" != "??" ]; then printf '%s' "$t"; return; fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    depth=$((depth + 1))
  done
}

tty="$(find_tty)"

# Set the terminal title via OSC 0 (works in Zed, iTerm, Terminal.app, etc.).
set_title() {
  local title="$1"
  [ -z "$tty" ] && return
  [ -w "/dev/$tty" ] || return
  printf '\033]0;%s\007' "$title" > "/dev/$tty" 2>/dev/null
}

# --- session ended: clear state + reset title ---
if [ "$status" = "end" ]; then
  rm -f "$f" "$dir/$sid.activity"
  set_title "bash"
  exit 0
fi

cwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
cwd="${cwd//\"/}"
ts="$(date +%s)"
term="${TERM_PROGRAM:-}"

# When Claude fires a Notification, the payload carries a "message" telling us
# *why* it needs you (e.g. permission request). Capture it for the dock popup.
reason=""
[ "$status" = "waiting" ] && rm -f "$dir/$sid.activity"
if [ "$status" = "waiting" ]; then
  reason="$(printf '%s' "$payload" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  reason="${reason//\\/}"     # drop backslashes so the JSON stays valid
fi

# Display name: explicit override wins, else the cwd's last folder.
# Set `export CLAUDE_SESSION_NAME=my-name` in a terminal to label it.
. "$HOME/.claude/hooks/session-name.sh"
name="$(session_name "$payload")"

# Rename the terminal so the state is visible at a glance.
if [ "$status" = "waiting" ]; then
  set_title "$name · waiting for input"
else
  set_title "$name · working"
fi

account="$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
printf '{"session_id":"%s","status":"%s","cwd":"%s","ts":%s,"tty":"%s","term":"%s","name":"%s","reason":"%s","account":"%s"}\n' \
  "$sid" "$status" "$cwd" "$ts" "$tty" "$term" "$name" "$reason" "$account" > "$f"

exit 0
