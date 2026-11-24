#!/bin/bash
# Docker healthcheck: healthy when the launcher runs and its log moved in the last 10 minutes (it writes a memory line every 5 minutes
# even while the world is paused with nobody there; a frozen game is restarted by the launcher's own watchdog, a missing process by the entrypoint).
pgrep -f 'mono MPFever.exe' >/dev/null || { echo "launcher not running"; exit 1; }
f=$(ls -t /data/srv/logs/launcher-*.log 2>/dev/null | head -1)
[ -n "$f" ] || { echo "no launcher log yet"; exit 1; }
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
[ "$age" -lt 600 ] || { echo "launcher log silent for ${age}s"; exit 1; }
echo ok
