"""Print a one-line detail for a toast from a Claude Code transcript.

Usage: python3 -I detail.py <transcript_path> permission|done
  permission -> the pending tool call, e.g. "Bash: npm install"
  done       -> first line of the last assistant text reply
"""
import json
import os
import re
import sys

TAIL_BYTES = 512 * 1024


def entries(path):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL_BYTES))
        lines = f.read().decode("utf-8", "replace").splitlines()
    for line in reversed(lines):
        try:
            yield json.loads(line)
        except ValueError:
            continue


def blocks(entry):
    if entry.get("type") != "assistant":
        return []
    content = (entry.get("message") or {}).get("content")
    return list(reversed(content)) if isinstance(content, list) else []


def clean(text, limit=90):
    text = re.sub(r"[`*_#>]+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def tool_summary(name, inp):
    short = name.split("__")[-1]
    for key in ("command", "file_path", "path", "url", "pattern", "query", "description", "prompt"):
        val = inp.get(key)
        if isinstance(val, str) and val.strip():
            if key in ("file_path", "path"):
                val = os.path.basename(val.rstrip("/")) or val
            return f"{short}: {clean(val.splitlines()[0], 70)}"
    return short


def main():
    if len(sys.argv) < 3 or not os.path.isfile(sys.argv[1]):
        return
    path, kind = sys.argv[1], sys.argv[2]
    for entry in entries(path):
        for b in blocks(entry):
            if kind == "permission" and b.get("type") == "tool_use":
                print(tool_summary(b.get("name", ""), b.get("input") or {}))
                return
            if kind == "done" and b.get("type") == "text" and b.get("text", "").strip():
                first = next((l for l in b["text"].splitlines() if l.strip()), "")
                print(clean(first))
                return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
