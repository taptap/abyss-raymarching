#!/usr/bin/env bash
# 单帧：tools/abyss/one.sh <t> <out.png> [debug(lua表)] [w] [h]
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$1"; OUT="$2"; DBG="${3:-nil}"; W="${4:-1280}"; H="${5:-540}"
NAME="abyss_one_$$"
SAVE=${ABYSS_SAVE_DIR:?请把 ABYSS_SAVE_DIR 设为引擎本地存档目录（见 tools/abyss/README.md）}/$NAME
rm -rf "$SAVE"
ENT="dev_one_$$.lua"
cat > "$PROJECT/scripts/$ENT" <<LUA
ONE = { t = $T, w = $W, h = $H, out = "$NAME", debug = $DBG, sub = ${SUB:-4} }
require "dev_one"
LUA
ENTRY=$ENT W=320 H=180 SHOT=.tmp/dev/screen_$$.png TIMEOUT=${TIMEOUT:-600} "${URHOX_RUN:-$PROJECT/tools/run-local.sh}" shot 99999 2>&1 \
  | grep -E "ERROR|rror" | grep -v -E "audio|UI\(" | tail -3 || true
rm -f "$PROJECT/scripts/$ENT"
cp "$SAVE/f00000.png" "$OUT" && echo "saved $OUT"
rm -rf "$SAVE"
