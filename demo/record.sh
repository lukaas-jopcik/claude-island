#!/bin/bash
# Records the raw demo footage: the real app in demo mode (made-up sessions, nothing personal), a scripted storyline.
# Quit your own Claude Island first (two islands would fight over the notch and the hotkeys).
# Usage: demo/record.sh [out.mov]        needs Screen Recording permission for your terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-demo/raw.mov}"
APP="$PWD/build/Claude Island.app/Contents/MacOS/claude-island"
WORK="$(mktemp -d)"; H="$WORK/home"
[ -x "$APP" ] || scripts/build.sh
swiftc -O demo/backdrop.swift -o "$WORK/backdrop" 2>/dev/null
demo/fixture.sh "$H"
E="$H/.claude/notifier/events"; S="$H/.claude/session-state"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

# the overview closes a few seconds after the pointer leaves it, so the recording parks the pointer over it (and puts yours back)
cat > "$WORK/mouse.swift" <<'SWIFT'
import CoreGraphics
let a = CommandLine.arguments
if a.count == 3, let x = Double(a[1]), let y = Double(a[2]) { CGWarpMouseCursorPosition(CGPoint(x: x, y: y)) }
else { let p = CGEvent(source: nil)!.location; print(Int(p.x), Int(p.y)) }
SWIFT
swiftc -O "$WORK/mouse.swift" -o "$WORK/mouse" 2>/dev/null
HOME_PTR="$("$WORK/mouse")"
trap 'kill $(jobs -p) 2>/dev/null || true; "$WORK/mouse" $HOME_PTR 2>/dev/null || true; rm -rf "$WORK"' EXIT
"$WORK/mouse" 300 600
SW="$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)')"   # main display width in points: the notch sits in the middle
CX=$((SW / 2))

"$WORK/backdrop" >/dev/null & sleep 1
ISLAND_DEMO=1 ISLAND_HOME="$H" "$APP" >/dev/null 2>&1 & sleep 3

# helpers ---------------------------------------------------------------------------------------------------------------
n=0
ev() { n=$((n+1)); printf '%s' "$1" > "$E/$n.json"; }                 # raw event json
banner() { ev "{\"kind\":\"$1\",\"title\":\"$2\",\"message\":\"$3\",\"project\":\"$4\",\"session\":\"$5\",\"term\":\"zed\"}"; }
# flip <session> <status> <reason> <activity> : rewrite a session's state like the hooks do
flip() {
  python3 -I - "$S" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, time
d, sid, status, reason, act = sys.argv[1:6]
p = f"{d}/{sid}.json"; j = json.load(open(p))
j.update(status=status, reason=reason, ts=int(time.time()))
json.dump(j, open(p, "w"))
import os
a = f"{d}/{sid}.activity"
if act: open(a, "w").write(act + "\n")
elif os.path.exists(a): os.remove(a)
PY
}

# storyline -------------------------------------------------------------------------------------------------------------
screencapture -v -V 31 -R $((CX - 320)),0,640,580 "$OUT" &
REC=$!
sleep 1.5                                                                              # the island at rest, hidden in the notch
banner permission "Needs permission" "Bash: rm -rf build && git push --force" mobile-app mobile-app   # the hook: you were in another app
sleep 5.0
banner input "Waiting for input" "Which database should the migration target?" docs-site docs-site
sleep 5.0
flip api-gateway waiting "" ""
banner done "Done" "All 42 tests pass" api-gateway api-gateway
sleep 4.5
ev '{"kind":"overview"}'                                                               # the whole picture
sleep 1.0; "$WORK/mouse" $((CX - 45)) 14
sleep 3.0
flip docs-site working "" "Running the migration"                                      # you answered: the row comes alive
sleep 3.5
ev '{"kind":"overview","expand":"storefront"}'                                         # a session's task queue
sleep 5.0
ev '{"kind":"collapse"}'
sleep 0.5; "$WORK/mouse" 300 600
wait $REC || true
echo "recorded $OUT"
