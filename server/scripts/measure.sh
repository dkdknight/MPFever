#!/bin/bash
# Memory and CPU of the running server, from inside the container:  docker compose exec mpfever-server /opt/mpfever/scripts/measure.sh
# Distinguishes the container's cgroup (anonymous memory, page cache, shared), each process (RSS and PSS = its fair share of shared pages) and CPU over 30 s.
cg=/sys/fs/cgroup
echo "== container (cgroup)"
if [ -f $cg/memory.current ]; then
  awk -v cur="$(cat $cg/memory.current)" '$1=="anon"{a=$2} $1=="file"{f=$2} $1=="shmem"{s=$2} END{printf "total %.0f MB  anonymous %.0f MB  page cache %.0f MB  shared(shmem) %.0f MB\n", cur/1048576, a/1048576, f/1048576, s/1048576}' $cg/memory.stat
fi
echo "== processes (RSS / PSS MB)"
ps -eo pid=,comm=,args= | while read -r pid comm args; do
  [ -r /proc/$pid/smaps_rollup ] || continue
  awk -v p="$pid" -v n="${args:0:46}" '$1=="Rss:"{r=$2} $1=="Pss:"{s=$2} END{printf "%8.0f %8.0f  %s\n", r/1024, s/1024, n}' /proc/$pid/smaps_rollup
done | sort -rn | head -8
echo "== CPU over 30 s (cores)"
g=$(pgrep -f 'TransportFever3.exe --script' | tail -1); d=$(pgrep -f 'dockhost.exe' | head -1)
for p in $g $d; do
  c0=$(awk '{print $14+$15}' /proc/$p/stat); sleep 30; c1=$(awk '{print $14+$15}' /proc/$p/stat)
  printf "pid %s %-28s %.2f\n" "$p" "$(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-28)" "$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.2f", (b-a)/100/30}')"
done
f=$(ls -t /data/srv/logs/launcher-*.log 2>/dev/null | head -1)
[ -n "$f" ] && { echo "== sync"; grep "Sync check" "$f" | tail -1 | cut -c1-90; echo "out of sync so far: $(grep -c 'OUT OF SYNC' "$f")"; }
