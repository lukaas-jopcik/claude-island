# Resolve the display name of a Claude Code session (shared by notify.sh and session-state.sh).
# Usage: session_name "<hook payload json>"
# Order: $CLAUDE_SESSION_NAME → /rename title from the transcript → basename of cwd.
session_name() {
  local payload="$1" name tp cwd
  name="${CLAUDE_SESSION_NAME:-}"
  if [ -z "$name" ]; then
    tp="$(printf '%s' "$payload" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      name="$(/usr/bin/grep -o '"customTitle":"[^"]*"' "$tp" 2>/dev/null | tail -n1 | sed 's/^"customTitle":"//; s/"$//')"
    fi
  fi
  if [ -z "$name" ]; then
    cwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    name="$(basename "${cwd:-claude}")"
  fi
  printf '%s' "$name"
}
