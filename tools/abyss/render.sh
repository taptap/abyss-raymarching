#!/usr/bin/env bash
# 由同一场景逐帧渲染 PNG 序列并合成 MP4（可分段并行）
# 用法：tools/abyss/render.sh <name> <w> <h> <fps> <seconds> <sub> <segments> [start]
#   例：tools/abyss/render.sh preview 640 270 30 30 1 1
#       tools/abyss/render.sh final 2560 1080 60 30 2 3
# 输出：.tmp/<name>.mp4（帧序列在引擎本地存档目录 $ABYSS_SAVE_DIR/abyss_<name>/）
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="$1"; W="$2"; H="$3"; FPS="$4"; SECS="$5"; SUB="$6"; SEG="${7:-1}"; START="${8:-0}"
TOTAL=$(python3 -c "print(int(round($FPS*$SECS)))")
DIR="abyss_$NAME"
SAVE=${ABYSS_SAVE_DIR:?请把 ABYSS_SAVE_DIR 设为引擎本地存档目录（见 tools/abyss/README.md）}/$DIR
rm -rf "$SAVE"; mkdir -p "$PROJECT/.tmp/logs"
THREADS=$(( $(nproc) / SEG ))
pids=()
for ((k=0; k<SEG; k++)); do
  a=$(( TOTAL * k / SEG )); b=$(( TOTAL * (k + 1) / SEG ))
  n=$(( b - a ))
  st=$(python3 -c "print($START + $a / $FPS)")
  ENT="rec_${NAME}_$k.lua"
  cat > "$PROJECT/scripts/$ENT" <<LUA
RECORD_OVERRIDE = { w = $W, h = $H, fps = $FPS, frames = $n, start = $st, sub = $SUB, warm = 16,
    out = "$DIR", indexOffset = $a }
require "record"
LUA
  ( LP_NUM_THREADS=$THREADS ENTRY=$ENT W=320 H=180 SHOT=.tmp/logs/${NAME}_$k.png TIMEOUT=${TIMEOUT:-36000} \
      "${URHOX_RUN:-$PROJECT/tools/run-local.sh}" shot 9999999 > "$PROJECT/.tmp/logs/${NAME}_$k.log" 2>&1; \
      rm -f "$PROJECT/scripts/$ENT" ) &
  pids+=($!)
  echo "segment $k: frames $a..$((b-1)) start=$st threads=$THREADS"
done
for p in "${pids[@]}"; do wait "$p"; done
cnt=$(ls "$SAVE" | wc -l)
echo "frames on disk: $cnt / $TOTAL"
ffmpeg -y -loglevel error -framerate "$FPS" -i "$SAVE/f%05d.png" -c:v libx264 -preset slow -crf ${CRF:-16} \
  -pix_fmt yuv420p -movflags +faststart -tune film "$PROJECT/.tmp/$NAME.mp4"
ls -la "$PROJECT/.tmp/$NAME.mp4"
