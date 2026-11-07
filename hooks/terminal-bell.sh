#!/bin/bash
# Ring the bell in the terminal that runs Claude Code (Zed marks the tab).
# Hooks have no controlling tty, so walk up the process tree to find one.
pid=$$
for _ in 1 2 3 4 5 6 7 8; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -z "$pid" || "$pid" -le 1 ]] && break
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  if [[ -n "$t" && "$t" != "??" ]]; then
    printf '\a' > "/dev/$t" 2>/dev/null
    break
  fi
done
exit 0
