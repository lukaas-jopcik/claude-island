#!/usr/bin/env python3
"""Stop hook dispatcher: the Claude Island queue decides first, then the usual Stop hooks run.

If the queue continues the session, the session stays "working" and Claude gets the next task
(Stop hook `decision: block`). Otherwise session-state, the notification and the bell run as before,
with the queue's own title when it paused or finished. Any failure falls back to the normal Stop.
"""
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
HOOKS = os.path.join(HOME, ".claude", "hooks")
sys.path.insert(0, os.path.join(HOME, ".claude", "island"))

raw = sys.stdin.buffer.read()


def run(cmd, env=None):
    try:
        subprocess.run(cmd, input=raw, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=6, env=env)
    except Exception:
        pass


def session_name():
    try:
        r = subprocess.run(["/bin/bash", "-c", '. "$1"; session_name "$2"', "_",
                            os.path.join(HOOKS, "session-name.sh"), raw.decode("utf-8", "replace")],
                           capture_output=True, timeout=3)
        return r.stdout.decode().strip()
    except Exception:
        return ""


out, note = None, None
try:
    import taskqueue as island_queue  # ~/.claude/island/taskqueue.py
    out, note = island_queue.stop(json.loads(raw or b"{}"), session_name())
except Exception:
    out, note = None, None

if out:
    run([os.path.join(HOOKS, "session-state.sh"), "working"])
    sys.stdout.write(json.dumps(out))
    sys.exit(0)

run([os.path.join(HOOKS, "session-state.sh"), "waiting"])
env = dict(os.environ)
if note:
    env["ISLAND_KIND"], env["ISLAND_TITLE"], env["ISLAND_MSG"] = note
run([os.path.join(HOOKS, "notify.sh"), "done"], env=env)
run([os.path.join(HOOKS, "terminal-bell.sh")])
sys.exit(0)
