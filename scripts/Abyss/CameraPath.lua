-- 巡航镜头路径：一次连续穿行，前 30 s 为开场；30–44 s 穿过连廊进入下一座井，
-- 并无缝接回开场位置（位置 +240 m、偏航 +360°），所以巡航可以无限循环。
-- 关键帧：{ 时间, x, y, z, 偏航°, 俯仰° }。偏航 0 = 朝北(+Z)，90 = 朝东(+X)。
-- 用非均匀 Catmull-Rom（Hermite）插值，位置、朝向与速度都 C1 连续。

local CameraPath = {}

CameraPath.PERIOD = 44.0
CameraPath.LOOP_DZ = 240.0
CameraPath.LOOP_YAW = 360.0
CameraPath.OPENING = 30.0

local K = {
    -- 检修平台：从连廊口缓慢探出，护栏（z = -38.3）约 6.4 s 掠过画面下方；锻炉与下层环廊一直在画面里
    { 0.0, -33.80, 1.68, -45.20, 3.0, -4.5 },
    { 2.0, -33.74, 1.72, -43.30, 3.5, -7.0 },
    { 4.0, -33.66, 1.85, -41.20, 4.0, -11.0 },
    { 6.0, -33.55, 2.05, -38.80, 4.5, -15.0 },
    { 8.0, -33.45, 1.30, -34.60, 5.0, -20.0 },
    -- 离开平台向下，贴着锻炉西侧前进
    { 10.0, -33.70, -3.00, -28.00, 5.4, -24.0 },
    { 12.0, -34.10, -8.50, -16.50, 5.8, -12.0 },
    { 14.0, -33.60, -13.50, 0.50, 10.0, -6.0 },
    { 15.5, -29.20, -21.50, 15.50, 30.0, -24.0 },
    -- 低头俯冲，从货运桥下穿过
    { 16.4, -24.20, -34.00, 21.00, 39.0, -38.0 },
    { 17.2, -19.30, -47.20, 26.60, 46.0, -33.0 },
    { 18.0, -14.40, -55.60, 32.60, 53.0, -16.0 },
    { 18.8, -10.60, -57.20, 38.60, 70.0, 2.0 },
    -- 穿桥后回望头顶的桥梁桁架
    { 19.6, -8.70, -56.90, 43.40, 100.0, 18.0 },
    { 20.5, -8.00, -55.00, 46.40, 155.0, 32.0 },
    { 21.5, -8.40, -50.50, 48.20, 210.0, 41.0 },
    { 22.3, -9.20, -44.50, 49.00, 247.0, 46.0 },
    -- 仰头沿升降塔爬升
    { 23.0, -10.50, -36.00, 49.00, 270.0, 50.0 },
    { 24.0, -11.00, -24.00, 48.60, 290.0, 52.0 },
    { 25.0, -11.50, -11.50, 48.00, 307.0, 47.0 },
    { 26.0, -12.50, 0.50, 46.80, 321.0, 38.0 },
    { 27.0, -14.50, 11.50, 43.20, 334.0, 26.0 },
    -- 越过上层平台，望向下一座井腔（先在平台内沿 z=38.25 以南爬过护栏高度，再从约 5 m 高处越过平台）
    { 28.0, -17.50, 21.50, 36.00, 344.0, 14.0 },
    { 28.8, -23.00, 27.40, 36.80, 350.0, 5.0 },
    { 29.5, -29.50, 29.00, 43.00, 356.0, -1.0 },
    { 30.0, -32.60, 29.50, 48.00, 360.0, -3.0 },
    -- 循环段：穿过倾斜连廊，降到下一座井的检修平台（末端平滑减速，接回开场的慢速推进）
    { 32.0, -33.80, 29.60, 66.00, 360.5, -4.0 },
    { 34.0, -33.80, 23.00, 96.00, 361.0, -6.0 },
    { 36.0, -33.80, 16.00, 128.00, 361.5, -7.0 },
    { 38.0, -33.80, 9.50, 158.00, 362.0, -7.0 },
    { 40.0, -33.80, 4.00, 178.00, 362.4, -6.5 },
    { 41.0, -33.80, 2.60, 186.40, 362.6, -6.0 },
    { 42.0, -33.80, 1.95, 191.20, 362.8, -5.4 },
    { 43.0, -33.80, 1.75, 193.60, 362.9, -4.9 },
}

local N = #K

-- 取第 i 个关键帧（可越界，按周期平移）
local function key(i)
    local k = ((i - 1) % N) + 1
    local cyc = math.floor((i - 1) / N)
    local e = K[k]
    return e[1] + cyc * CameraPath.PERIOD,
        { e[2], e[3], e[4] + cyc * CameraPath.LOOP_DZ, e[5] + cyc * CameraPath.LOOP_YAW, e[6] }
end

local function tangent(tPrev, vPrev, t0, v0, tNext, vNext, ch)
    local s0 = (v0[ch] - vPrev[ch]) / (t0 - tPrev)
    local s1 = (vNext[ch] - v0[ch]) / (tNext - t0)
    return (s0 * (tNext - t0) + s1 * (t0 - tPrev)) / (tNext - tPrev)
end

-- 返回 x, y, z, yaw, pitch（未加震动）
local function evalRaw(t)
    local cyc = math.floor(t / CameraPath.PERIOD)
    local tl = t - cyc * CameraPath.PERIOD
    local j = N
    for i = 1, N do
        local nextT = (i < N) and K[i + 1][1] or CameraPath.PERIOD
        if tl >= K[i][1] and tl < nextT then
            j = i
            break
        end
    end
    local jj = j + cyc * N
    local tA, vA = key(jj)
    local tB, vB = key(jj + 1)
    local tP, vP = key(jj - 1)
    local tN, vN = key(jj + 2)
    local h = tB - tA
    local s = (t - tA) / h
    local s2, s3 = s * s, s * s * s
    local h00 = 2 * s3 - 3 * s2 + 1
    local h10 = s3 - 2 * s2 + s
    local h01 = -2 * s3 + 3 * s2
    local h11 = s3 - s2
    local out = {}
    for ch = 1, 5 do
        local mA = tangent(tP, vP, tA, vA, tB, vB, ch)
        local mB = tangent(tA, vA, tB, vB, tN, vN, ch)
        out[ch] = h00 * vA[ch] + h10 * h * mA + h01 * vB[ch] + h11 * h * mB
    end
    return out[1], out[2], out[3], out[4], out[5]
end

CameraPath.EvalRaw = evalRaw

-- 巡航位姿：位置 Vector3、偏航/俯仰/横滚（度）。附带极轻的机械震动与转弯侧倾
function CameraPath.Evaluate(t)
    local x, y, z, yaw, pitch = evalRaw(t)
    local _, _, _, yawA = evalRaw(t - 0.15)
    local _, _, _, yawB = evalRaw(t + 0.15)
    local yawRate = (yawB - yawA) / 0.3
    local roll = math.max(-3.5, math.min(3.5, -yawRate * 0.045))
    -- 机械震动：几组不同频率的小正弦，幅度毫米级
    local sx = math.sin(t * 11.3) * 0.004 + math.sin(t * 17.9 + 1.3) * 0.002
    local sy = math.sin(t * 13.7 + 0.4) * 0.004 + math.sin(t * 23.1) * 0.0015
    local sz = math.sin(t * 9.7 + 2.2) * 0.003
    yaw = yaw + math.sin(t * 9.1) * 0.04 + math.sin(t * 15.3 + 0.8) * 0.02
    pitch = pitch + math.sin(t * 12.3 + 1.0) * 0.035
    return Vector3(x + sx, y + sy, z + sz), yaw, pitch, roll
end

-- 找到离给定位置最近的路径时间（用于 R 恢复巡航）。返回路径时间与需要附加的世界偏移
function CameraPath.Nearest(pos)
    local best, bestT, bestOff = 1e30, 0.0, Vector3(0, 0, 0)
    local t = 0.0
    while t < CameraPath.PERIOD do
        local x, y, z = evalRaw(t)
        local kx = math.floor((pos.x - x) / 480.0 + 0.5)
        local ky = math.floor((pos.y - y) / 300.0 + 0.5)
        local kz = math.floor((pos.z - z) / 240.0 + 0.5)
        local dx = pos.x - (x + kx * 480.0)
        local dy = pos.y - (y + ky * 300.0)
        local dz = pos.z - (z + kz * 240.0)
        local d = dx * dx + dy * dy + dz * dz
        if d < best then
            best, bestT = d, t + kz * CameraPath.PERIOD
            bestOff = Vector3(kx * 480.0, ky * 300.0, 0.0)
        end
        t = t + 0.2
    end
    return bestT, bestOff, math.sqrt(best)
end

return CameraPath
