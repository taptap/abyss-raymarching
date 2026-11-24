-- 录制入口：由同一场景按固定帧率逐帧渲染，PNG 写到 RECORD.out，之后用 ffmpeg 合成 MP4。
-- 参数可在加载前由 RECORD_OVERRIDE（全局表）覆盖，用于分段并行录制与低分辨率预览。

RECORD = {
    w = 2560,
    h = 1080,
    fps = 60,
    frames = 1800,       -- 30 s
    start = 0.0,         -- 开场时间（秒）
    warm = 16,           -- 首帧前的 TAA 预热帧
    sub = 1,             -- 每帧子采样数（>1 时为累积抗锯齿 + 快门运动模糊）
    shutter = 0.5,
    out = "abyss_frames",       -- 相对路径：引擎把它放进项目存档目录（绝对路径会被拒绝）
    indexOffset = 0,
    flipY = true,         -- GL 回读是自下而上的行序
}

if RECORD_OVERRIDE then
    for k, v in pairs(RECORD_OVERRIDE) do
        RECORD[k] = v
    end
end

require "main"
