#!/usr/bin/env bash
# 渲染一组时间点（每隔 STEP 秒一帧，共 N 帧）并拼成联系表 .tmp/sheet.png
# 用法：tools/abyss/sheet.sh [start] [step] [n] [w] [h] [sub]
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
START="${1:-0}"; STEP="${2:-2.5}"; N="${3:-12}"; W="${4:-640}"; H="${5:-270}"; SUB="${6:-4}"
OUTNAME="abyss_sheet"
SAVE=${ABYSS_SAVE_DIR:?请把 ABYSS_SAVE_DIR 设为引擎本地存档目录（见 tools/abyss/README.md）}/$OUTNAME
rm -rf "$SAVE"
FPS=$(python3 -c "print(1.0/$STEP)")
cat > "$PROJECT/scripts/dev_sheet.lua" <<LUA
DEV_STILL = { start = $START, fps = $FPS, frames = $N, w = $W, h = $H, warm = 1, out = "$OUTNAME" }
RECORD_OVERRIDE_EXTRA = { sub = $SUB, shutter = 0.02 }
require "dev_still"
LUA
ENTRY=dev_sheet.lua W=320 H=180 SHOT=.tmp/dev/screen.png TIMEOUT=${TIMEOUT:-1200} "${URHOX_RUN:-$PROJECT/tools/run-local.sh}" shot 99999 2>&1 \
  | grep -E "REC\]|ERROR|rror" | grep -v -E "audio|UI\(" | tail -4
python3 - "$SAVE" "$PROJECT/.tmp/sheet.png" "$START" "$STEP" <<'PY'
import sys, glob, os
from PIL import Image, ImageDraw
d, out, start, step = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
files = sorted(glob.glob(os.path.join(d, "f*.png")))
ims = [Image.open(f).convert("RGB") for f in files]
if not ims: sys.exit("no frames")
w, h = ims[0].size
cols = 2
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols, h * rows), (0, 0, 0))
for i, im in enumerate(ims):
    x, y = (i % cols) * w, (i // cols) * h
    sheet.paste(im, (x, y))
    dr = ImageDraw.Draw(sheet)
    dr.text((x + 6, y + 4), "t=%.1f" % (start + i * step), fill=(255, 255, 0))
sheet.save(out)
print("sheet", out, len(ims), "frames")
PY
