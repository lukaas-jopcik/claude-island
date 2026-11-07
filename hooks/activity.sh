# PreToolUse hook: records what the session is doing right now for Claude Island.
# Writes one short English line to ~/.claude/session-state/<sid>.activity. Must stay fast and silent.
payload="$(cat)"
field() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1; }

sid="$(field session_id)"
[ -z "$sid" ] && exit 0
tool="$(field tool_name)"
file="$(basename "$(field file_path)" 2>/dev/null)"

case "$tool" in
  Bash)
    d="$(field description)"
    [ -z "$d" ] && d="Running $(field command | cut -c1-48)"
    text="$d" ;;
  Edit|MultiEdit|Write|NotebookEdit) text="Editing ${file:-a file}" ;;
  Read) text="Reading ${file:-a file}" ;;
  Grep|Glob) text="Searching the code" ;;
  WebFetch|WebSearch) text="Browsing the web" ;;
  Agent|Task) text="Running an agent" ;;
  Workflow) text="Running a workflow" ;;
  TodoWrite|TaskCreate|TaskUpdate) text="Planning" ;;
  AskUserQuestion) text="Asking you a question" ;;
  mcp__*) server="$(printf '%s' "$tool" | awk -F'__' '{print $2}' | sed 's/^plugin_[^_]*_//')"; text="Using $server" ;;
  "") exit 0 ;;
  *) text="$tool" ;;
esac

printf '%s\n' "$text" | cut -c1-70 > "$HOME/.claude/session-state/$sid.activity"
exit 0
