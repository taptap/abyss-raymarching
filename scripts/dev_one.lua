-- 开发：单帧，参数来自 ONE（由命令行生成）
DEV_STILL = { start = ONE.t, w = ONE.w or 1280, h = ONE.h or 540, warm = 1, out = ONE.out or "abyss_one" }
RECORD_OVERRIDE_EXTRA = { sub = ONE.sub or 4, shutter = 0.02 }
DEBUG_VIEW = ONE.debug
require "dev_still"
