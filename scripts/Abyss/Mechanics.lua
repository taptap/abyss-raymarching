-- 各机构的运动状态：只由时间决定（录制可逐帧重现），每种机构用自己的速度与周期
-- 锻炉：起伏 + 轻微倾斜（四根活塞因此各自伸缩）、叶片缓慢旋转
-- 货车：两列，方向相反、速度不同；升降舱：上下往返并在两端停靠，配重反向运动

local Mechanics = {}

local TAU = math.pi * 2.0

local function smootherstep(x)
    x = math.max(0.0, math.min(1.0, x))
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
end

local CORNERS = { { 14.85, 14.85 }, { -14.85, 14.85 }, { 14.85, -14.85 }, { -14.85, -14.85 } }

Mechanics.CAB_TOP = 26.3      -- 舱体中心高度：停靠上层平台（地面 24）
Mechanics.CAB_BOTTOM = -45.7  -- 停靠桥面层（地面 -48）

---@param t number 动画时间（秒）
function Mechanics.Evaluate(t)
    local s = {}
    s.furnY = -14.0 + 0.9 * math.sin(t * TAU / 7.3)
    s.tiltX = math.rad(1.1) * math.sin(t * TAU / 11.0 + 0.7)
    s.tiltZ = math.rad(0.8) * math.sin(t * TAU / 13.0 + 2.1)
    s.blade = (t * 0.21) % TAU
    s.flicker = 0.93 + 0.05 * math.sin(t * 11.3) * math.sin(t * 6.1 + 1.0) + 0.02 * math.sin(t * 29.0)
    s.cx, s.sx = math.cos(s.tiltX), math.sin(s.tiltX)
    s.cz, s.sz = math.cos(s.tiltZ), math.sin(s.tiltZ)

    -- 活塞杆下端：锻炉局部坐标 (±14.85, 6.35, ±14.85) 变换回竖井坐标
    -- 着色器里 furnaceFrame = Rz · Rx · (q - C)，这里做逆变换 q = C + Rx⁻¹ · Rz⁻¹ · fp
    s.pist = {}
    for i, c in ipairs(CORNERS) do
        local fx, fy, fz = c[1], 6.35, c[2]
        local x1 = s.cz * fx - s.sz * fy
        local y1 = s.sz * fx + s.cz * fy
        local y2 = s.cx * y1 - s.sx * fz
        local z2 = s.sx * y1 + s.cx * fz
        s.pist[i] = Vector4(x1, y2 + s.furnY, z2, 0.0)
    end

    -- 货车车头的世界 x（周期 480 m，与相机回绕周期一致）
    s.trainA = ((9.0 * t - 140.0 + 240.0) % 480.0) - 240.0
    s.trainB = ((32.3 - 6.5 * t + 240.0) % 480.0) - 240.0

    -- 升降舱：28 s 一个往返，下行 10 s → 底部停 4 s → 上行 10 s → 顶部停 4 s
    local u = (t - 20.0) % 28.0
    local top, bot = Mechanics.CAB_TOP, Mechanics.CAB_BOTTOM
    local y
    if u < 10.0 then
        y = top + (bot - top) * smootherstep(u / 10.0)
    elseif u < 14.0 then
        y = bot
    elseif u < 24.0 then
        y = bot + (top - bot) * smootherstep((u - 14.0) / 10.0)
    else
        y = top
    end
    s.cabY = y
    s.cwY = (top + bot) - y
    return s
end

return Mechanics
