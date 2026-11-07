#!/usr/bin/env python3
"""Claude Island session queue: shared store + Claude Code hook entry points.

Queue files live in ~/.claude/island/queues/<session_id>.json:
  {sid, cwd, name, profile, instructions, maxChain, chain, paused, pauseKind, pauseReason,
   tasks: [{id, text, state: queued|running|done, added, started, finished, rid, note}]}

The Claude Island app edits them; this script is the only thing that advances them.

  taskqueue.py stop   <name>   Stop hook. Prints {"decision":"block",...} when the next task should run.
  taskqueue.py prompt      UserPromptSubmit: you wrote to the session yourself, so the auto-chain count resets.

Safety rails (from the council review):
  - A task only counts as finished when Claude ends with "QUEUE: DONE". "QUEUE: BLOCKED", or no marker
    at all (a question, an error), pauses the queue and hands the session back to you.
  - The first task never fires on top of a turn that ended with a question.
  - At most `maxChain` tasks run in a row without you writing to the session (default 3).
  - Global pause: ~/.claude/island/paused. The Up-next banner can hold a task for 3 s before it fires.
  - Anything unexpected fails open: the session simply stops as it would without the queue.
"""
import fcntl
import json
import os
import re
import sys
import time

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".claude", "island")
QDIR = os.path.join(BASE, "queues")
HOLD = os.path.join(BASE, "hold")
EVENTS = os.path.join(HOME, ".claude", "notifier", "events")
HOLD_SECONDS = 3.0

PROFILES = {
    "continue": "",
    "verify": ("Before you finish, run the project's relevant tests, type checks and linters, "
               "and fix any failures your change caused. Report DONE only when they pass."),
    "ship": ("Before you finish, run the project's relevant tests, type checks and linters, and fix "
             "any failures your change caused. Then commit your changes with a clear message. Do not push."),
}

DONE_RE = re.compile(r"QUEUE:\s*DONE\b", re.I)
BLOCKED_RE = re.compile(r"QUEUE:\s*BLOCKED\b:?\s*(.*)", re.I)


# ---------------------------------------------------------------- store

class Locked:
    """Exclusive lock shared with the island app (flock on queues/.lock)."""

    def __enter__(self):
        os.makedirs(QDIR, exist_ok=True)
        self.fd = os.open(os.path.join(QDIR, ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def qpath(sid):
    return os.path.join(QDIR, os.path.basename(sid) + ".json")


def load(sid):
    try:
        with open(qpath(sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save(q):
    q["updated"] = time.time()
    p = qpath(q["sid"])
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(q, f, indent=1)
    os.replace(tmp, p)


def emit(kind, title, message, project, sid, action=""):
    os.makedirs(EVENTS, exist_ok=True)
    d = {"kind": kind, "title": title, "message": message, "project": project,
         "session": sid, "term": os.environ.get("TERM_PROGRAM", ""), "action": action}
    p = os.path.join(EVENTS, "%d-%d-q.json" % (time.time() * 1000, os.getpid()))
    with open(p + ".tmp", "w") as f:
        json.dump(d, f)
    os.replace(p + ".tmp", p)


# ---------------------------------------------------------------- transcript

def last_assistant_text(payload):
    t = payload.get("last_assistant_message")
    if isinstance(t, str) and t.strip():
        return t
    path = payload.get("transcript_path") or ""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 512 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "user" and not e.get("toolUseResult") and e.get("message", {}).get("role") == "user":
            c = e["message"].get("content")
            if isinstance(c, str) or (isinstance(c, list) and any(x.get("type") == "text" for x in c if isinstance(x, dict))):
                return ""  # reached the prompt that started this turn: no text reply in it
        if e.get("type") != "assistant":
            continue
        parts = [c.get("text", "") for c in e.get("message", {}).get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
        text = "\n".join(p for p in parts if p.strip())
        if text.strip():
            return text
    return ""


def ends_with_question(text):
    lines = [l.strip(" *_`>") for l in text.strip().splitlines() if l.strip()]
    return bool(lines) and lines[-1].endswith("?")


def first_line(text, n=90):
    for l in text.splitlines():
        l = l.strip(" #*_`>-")
        if l:
            return l if len(l) <= n else l[: n - 1] + "…"
    return ""


# ---------------------------------------------------------------- hooks

def instruction(q, task, index, total):
    parts = ["[Claude Island · queued task %d of %d]" % (index, total), "", task["text"].strip()]
    extra = [PROFILES.get(q.get("profile", "continue"), ""), (q.get("instructions") or "").strip()]
    extra = [x for x in extra if x]
    if extra:
        parts += [""] + extra
    parts += ["",
              "When you are completely finished, end your final message with a line `QUEUE: DONE`.",
              "If you cannot finish it, or you need a decision from me, end with `QUEUE: BLOCKED: <short reason>` instead."]
    return "\n".join(parts)


def pause(q, kind, reason):
    q["paused"], q["pauseKind"], q["pauseReason"] = True, kind, reason


def stop(payload, name):
    """Returns (hook_output or None, notification override or None)."""
    sid = payload.get("session_id") or ""
    if not sid or os.path.exists(os.path.join(BASE, "paused")):
        return None, None
    with Locked():
        q = load(sid)
        if not q or q.get("paused"):
            return None, None
        tasks = q.get("tasks", [])
        text = last_assistant_text(payload)
        running = next((t for t in tasks if t.get("state") == "running"), None)
        now = time.time()
        if running and not DONE_RE.search(text[-600:]) and not BLOCKED_RE.search(text[-600:]):
            time.sleep(0.4)  # the transcript may trail the Stop event by a moment
            text = last_assistant_text(payload) or text
        if running:
            tail = text[-600:]
            if DONE_RE.search(tail):
                running["state"], running["finished"] = "done", now
            else:
                m = BLOCKED_RE.search(tail)
                if m:
                    reason = first_line(m.group(1)) or "Needs your decision"
                    pause(q, "blocked", reason)
                    running["note"] = reason
                    save(q)
                    return None, ("blocked", "Queue paused", "Blocked: " + reason)
                pause(q, "needs", "Waiting for your reply")
                save(q)
                return None, ("blocked", "Queue paused", first_line(text) or "Waiting for your reply")
        elif ends_with_question(text):
            return None, None  # it asked you something: never answer it with the next task

        queued = [t for t in tasks if t.get("state") == "queued"]
        if not queued:
            save(q)
            if running:
                n = sum(1 for t in tasks if t.get("state") == "done")
                return None, ("done", "Queue finished", "%d task%s done" % (n, "" if n == 1 else "s"))
            return None, None
        limit = int(q.get("maxChain") or 3)
        if q.get("chain", 0) >= limit:
            ran = "1 task" if limit == 1 else "%d tasks" % limit
            pause(q, "limit", "Ran %s in a row" % ran)
            save(q)
            return None, ("blocked", "Queue paused", "Ran %s in a row, check the results" % ran)
        nxt = queued[0]
        save(q)

    # Up next: give a few seconds to hold it from the island (outside the lock)
    hold = os.path.join(HOLD, sid)
    try:
        os.remove(hold)
    except OSError:
        pass
    emit("working", "Up next", nxt["text"], name or q.get("name", ""), sid, action="hold")
    end = time.time() + HOLD_SECONDS
    while time.time() < end:
        if os.path.exists(hold):
            break
        time.sleep(0.1)

    with Locked():
        q = load(sid) or {}
        tasks = q.get("tasks", [])
        nxt = next((t for t in tasks if t.get("id") == nxt.get("id") and t.get("state") == "queued"), None)
        if os.path.exists(hold) or q.get("paused") or not nxt:
            try:
                os.remove(hold)
            except OSError:
                pass
            if not q.get("paused") and q:
                pause(q, "user", "Held")
                save(q)
            return None, ("idle", "Queue held", "Paused before the next task")
        nxt["state"], nxt["started"] = "running", time.time()
        q["chain"] = int(q.get("chain", 0)) + 1
        done = sum(1 for t in tasks if t.get("state") == "done")
        total = sum(1 for t in tasks if t.get("state") in ("done", "running", "queued"))
        save(q)
        return {"decision": "block", "reason": instruction(q, nxt, done + 1, total)}, None


def prompt(payload):
    sid = payload.get("session_id") or ""
    with Locked():
        q = load(sid)
        if not q:
            return
        q["chain"] = 0
        if q.get("paused") and q.get("pauseKind") in ("needs", "limit", "blocked"):
            q["paused"], q["pauseKind"], q["pauseReason"] = False, "", ""
        save(q)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    try:
        if mode == "prompt":
            prompt(payload)
        elif mode == "stop":
            out, note = stop(payload, sys.argv[2] if len(sys.argv) > 2 else "")
            print(json.dumps({"hook": out, "note": note}))
    except Exception:
        print(json.dumps({"hook": None, "note": None}))
