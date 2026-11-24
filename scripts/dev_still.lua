-- 开发用：渲染指定时间的单帧到 .tmp/dev（参数由 DEV_STILL 覆盖）
RECORD_OVERRIDE = {
    w = DEV_STILL and DEV_STILL.w or 640,
    h = DEV_STILL and DEV_STILL.h or 270,
    frames = DEV_STILL and DEV_STILL.frames or 1,
    start = DEV_STILL and DEV_STILL.start or 0.0,
    fps = DEV_STILL and DEV_STILL.fps or 60,
    warm = DEV_STILL and DEV_STILL.warm or 6,
    out = DEV_STILL and DEV_STILL.out or "abyss_dev",
    indexOffset = DEV_STILL and DEV_STILL.indexOffset or 0,
}
if RECORD_OVERRIDE_EXTRA then
    for k, v in pairs(RECORD_OVERRIDE_EXTRA) do
        RECORD_OVERRIDE[k] = v
    end
end
require "record"
