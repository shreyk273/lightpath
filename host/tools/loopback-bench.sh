#!/usr/bin/env bash
# Stream this PC to itself with Moonlight (Flatpak) and print Moonlight's end-of-session stats.
# The local window mirrors the virtual display, which keeps the desktop changing every frame:
# a worst-case, always-120-fps load for capture + encode.
#
#   host/tools/loopback-bench.sh [seconds] [moonlight stream options...]
#   host/tools/loopback-bench.sh 20 --resolution 3024x1964 --fps 120 --bitrate 150000 --video-codec HEVC
#
# Requires: the Moonlight Flatpak paired with this host (host/tools/pair-local.sh).
set -euo pipefail
DURATION="${1:-20}"; shift || true
ARGS=("$@")
((${#ARGS[@]})) || ARGS=(--resolution 3024x1964 --fps 120 --bitrate 150000 --video-codec HEVC)
PORT="${LIGHTPATH_BASE_PORT:-48989}"
LOG="$(mktemp -t lightpath-bench.XXXXXX.log)"
trap 'pkill -TERM -x moonlight 2>/dev/null || true' EXIT

flatpak run com.moonlight_stream.Moonlight stream "127.0.0.1:${PORT}" Desktop \
  --display-mode windowed --no-vsync --no-frame-pacing --quit-after --no-hdr "${ARGS[@]}" >"$LOG" 2>&1 &
start=$(date +%s.%N)
first=""
for _ in $(seq 1 $((DURATION * 10))); do
  if [[ -z "$first" ]] && grep -q "Received first video packet" "$LOG"; then
    first=$(grep -o "Received first video packet after [0-9]* ms" "$LOG")
  fi
  sleep 0.1
done
pkill -TERM -x moonlight || true
for _ in $(seq 1 50); do pgrep -x moonlight >/dev/null || break; sleep 0.1; done

echo "== moonlight ${ARGS[*]} (${DURATION}s)"
echo "${first:-no video received}"
sed -n '/Global video stats/,/rendering time/p' "$LOG" | sed '1d'
grep -m1 -o "Renderer '[^']*' chosen" "$LOG" || true
echo "log: $LOG"
