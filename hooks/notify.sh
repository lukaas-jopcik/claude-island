# Claude Code notification hook: shows a Liquid Glass toast (~/.claude/notifier/glass-toast).
# Usage: notify.sh input|done   (payload on stdin)
event="${1:-input}"
payload="$(cat)"
notifier="$HOME/.claude/notifier"

# Quiet modes: per-terminal env, global toggle (claude-quiet), active Focus, Zoom screen share.
[ -n "${CLAUDE_QUIET:-}" ] && exit 0
[ -f "$notifier/quiet" ] && exit 0
/usr/bin/grep -q '"storeAssertionRecords":\[{' "$HOME/Library/DoNotDisturb/DB/Assertions.json" 2>/dev/null && exit 0
pgrep -xq CptHost && exit 0

. "$HOME/.claude/hooks/session-name.sh"
name="$(session_name "$payload")"

field() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1; }
msg="$(field message)"
ntype="$(field notification_type)"
sid="$(field session_id)"
cwd="$(field cwd)"
transcript="$(field transcript_path)"
detail() { [ -f "$transcript" ] && /usr/bin/python3 -I "$notifier/detail.py" "$transcript" "$1" 2>/dev/null; }

case "$event" in
  done)
    kind="done"; title="Done"; duration=4
    msg="$(detail done)"
    [ -z "$msg" ] && msg="Ready for your next prompt"
    ;;
  *)
    duration=6
    case "$ntype$msg" in
      *permission*)
        kind="permission"; title="Needs permission"
        d="$(detail permission)"
        if [ -n "$d" ]; then
          msg="$d"
        else
          tool="$(printf '%s' "$msg" | sed -n 's/.*permission to use \(.*\)$/\1/p')"
          [ -n "$tool" ] && msg="Allow $tool?"
        fi
        ;;
      *)
        kind="input"; title="Waiting for input"
        if [ -z "$msg" ] || [ "$msg" = "Claude is waiting for your input" ]; then msg="Claude needs your reply"; fi
        ;;
    esac
    ;;
esac

# Claude Island queue overrides (set by stop.py when the queue paused or finished)
[ -n "${ISLAND_TITLE:-}" ] && { kind="${ISLAND_KIND:-$kind}"; title="$ISLAND_TITLE"; msg="${ISLAND_MSG:-$msg}"; }

# window-title hints used to skip the toast when you are already looking at this session
match="$name"
if [ -n "$cwd" ]; then
  match="$match,$(basename "$cwd")"
  # (no parent-folder hint: one Zed window holds sessions of all its subfolders, so it would hide them all)
fi

toast="$notifier/glass-toast"
island_pid="$(cat "$notifier/island.pid" 2>/dev/null)"
if [ -n "$island_pid" ] && kill -0 "$island_pid" 2>/dev/null; then
  # Claude Island is running: hand it the event (skipped when you are already looking at the session)
  # a paused queue always tells you, even when its window is in front
  if [ -z "${ISLAND_TITLE:-}" ]; then
    "$toast" --check-only 1 --kind "$kind" --term "${TERM_PROGRAM:-}" --match "$match" || exit 0
  fi
  mkdir -p "$notifier/events"
  /usr/bin/python3 -I -c 'import json,sys,os,time
k=["kind","title","message","project","session","term"]
d=dict(zip(k,sys.argv[2:]))
p=os.path.join(sys.argv[1],"%d-%d.json"%(time.time()*1000,os.getpid()))
open(p+".tmp","w").write(json.dumps(d)); os.rename(p+".tmp",p)' \
    "$notifier/events" "$kind" "$title" "$msg" "$name" "$sid" "${TERM_PROGRAM:-}"
elif [ -x "$toast" ]; then
  nohup "$toast" --kind "$kind" --title "$title" --message "$msg" --project "$name" \
    --term "${TERM_PROGRAM:-}" --session "$sid" --match "$match" --duration "$duration" >/dev/null 2>&1 &
else
  /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"$title · $name\"" >/dev/null 2>&1
fi

exit 0
