-- 配色方案：雾的近/远色、锻炉、能量槽、灯光颜色，以及雾密度与后期饱和度
-- 颜色均为线性 HDR 值（未做 gamma）。HUD 上的配色按钮按顺序循环切换。

local Palettes = {
    {
        name = "AMBER",          -- 琥珀炉火 + 深蓝深渊（默认）
        fogNear = { 0.055, 0.024, 0.009 },
        fogFar = { 0.011, 0.027, 0.062 },
        furn = { 1.0, 0.43, 0.11 },
        slot = { 0.16, 0.86, 1.0 },
        lamp = { 1.0, 0.6, 0.27 },
        density = 0.0085,
        saturation = 1.0,
        exposure = 1.0,
    },
    {
        name = "HAZE",           -- 橙色沙尘雾（更浓、更暖）
        fogNear = { 0.17, 0.07, 0.02 },
        fogFar = { 0.07, 0.035, 0.016 },
        furn = { 1.0, 0.52, 0.16 },
        slot = { 0.3, 0.8, 0.78 },
        lamp = { 1.0, 0.62, 0.3 },
        density = 0.0115,
        saturation = 0.92,
        exposure = 0.95,
    },
    {
        name = "MONO",           -- 冷灰单色，白热炉火
        fogNear = { 0.034, 0.039, 0.045 },
        fogFar = { 0.011, 0.014, 0.02 },
        furn = { 1.0, 0.82, 0.64 },
        slot = { 0.55, 0.95, 1.0 },
        lamp = { 0.92, 0.86, 0.78 },
        density = 0.0078,
        saturation = 0.3,
        exposure = 1.05,
    },
}

return Palettes
