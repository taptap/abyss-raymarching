-- 镜头控制
--  巡航：沿 CameraPath 自动穿行；鼠标移动只做小幅微调（停止移动 3 s 后回正）
--  接管：按住鼠标拖动 / WASD QE / 触屏 → 自由飞行，松手保留朝向
--  R 恢复巡航（从最近的路径点平滑过渡）；P 重播开场（短暂淡出淡入）
--  手机：右侧拖动转向，左下拖动飞行（虚拟摇杆）

local CameraPath = require("Abyss.CameraPath")

local Controls = {}

local DRAG_SENS = 0.14        -- 度 / 像素
local TOUCH_SENS = 0.2
local FLY_SPEED = 7.0         -- m/s
local BOOST = 4.0
local FINE_YAW = 7.0          -- 巡航时鼠标微调的最大角度
local FINE_PITCH = 4.5

local S = {
    mode = "cruise",          -- "cruise" | "manual"
    cruiseT = 0.0,
    cruiseOff = Vector3(0, 0, 0),
    blend = 1.0,              -- 恢复巡航时从手动位姿过渡到巡航位姿（1 = 已完成）
    blendFrom = nil,
    fineYaw = 0.0, finePitch = 0.0,
    fineTY = 0.0, fineTP = 0.0,
    idleMouse = 99.0,
    lastMouse = nil,
    pos = Vector3(0, 0, 0), yaw = 0.0, pitch = 0.0, roll = 0.0,
    vel = Vector3(0, 0, 0),
    dragging = false,
    touches = {},             -- touchID -> { role = "look"|"move", start = {x,y} }
    joy = { x = 0.0, y = 0.0, active = false, cx = 0, cy = 0 },
    fade = 0.0,               -- P 重播的淡出（0..1）
    fadeDir = 0.0,
    pendingReplay = false,
}
Controls.state = S

local function clamp(x, a, b)
    return math.max(a, math.min(b, x))
end

local function basisFrom(yawDeg, pitchDeg)
    local y, p = math.rad(yawDeg), math.rad(pitchDeg)
    local fwd = Vector3(math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p))
    local right = Vector3(math.cos(y), 0.0, -math.sin(y))
    return fwd, right
end

---@type fun(x: number, y: number): boolean
local isOverUI = function(x, y) return false end

function Controls.SetUIHitTest(fn)
    isOverUI = fn
end

local function takeOver()
    if S.mode ~= "manual" then
        S.mode = "manual"
        S.vel = Vector3(0, 0, 0)
        S.yaw = S.yaw + S.fineYaw
        S.pitch = S.pitch + S.finePitch
        S.fineYaw, S.finePitch, S.fineTY, S.fineTP = 0.0, 0.0, 0.0, 0.0
        S.roll = 0.0
        print("[Abyss] manual control")
    end
end

function Controls.ResumeCruise()
    if S.mode == "cruise" and S.blend >= 1.0 then
        return
    end
    local t, off, dist = CameraPath.Nearest(S.pos)
    S.cruiseT = t
    S.cruiseOff = off
    S.blendFrom = { pos = Vector3(S.pos.x, S.pos.y, S.pos.z), yaw = S.yaw, pitch = S.pitch, roll = S.roll }
    S.blend = 0.0
    S.mode = "cruise"
    S.vel = Vector3(0, 0, 0)
    print(string.format("[Abyss] resume cruise at t=%.1f (%.1f m away)", t, dist))
end

function Controls.Replay()
    S.pendingReplay = true
    S.fadeDir = 1.0
end

local function doReplay()
    S.mode = "cruise"
    S.cruiseT = 0.0
    S.cruiseOff = Vector3(0, 0, 0)
    S.blend = 1.0
    S.fineYaw, S.finePitch, S.fineTY, S.fineTP = 0.0, 0.0, 0.0, 0.0
    S.vel = Vector3(0, 0, 0)
    print("[Abyss] replay opening")
end

local function anyMoveKey()
    return input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_A)
        or input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_Q) or input:GetKeyDown(KEY_E)
end

local function updateTouches(W, H)
    local n = input:GetNumTouches()
    local seen = {}
    local lookDX, lookDY = 0.0, 0.0
    local joyActive = false
    for i = 0, n - 1 do
        local ts = input:GetTouch(i)
        if ts then
            local id = ts.touchID
            seen[id] = true
            local px, py = ts.position.x, ts.position.y
            local tr = S.touches[id]
            if not tr then
                if isOverUI(px, py) then
                    tr = { role = "ui" }
                elseif px < W * 0.42 and py > H * 0.45 then
                    tr = { role = "move", sx = px, sy = py }
                    S.joy.cx, S.joy.cy = px, py
                else
                    tr = { role = "look" }
                end
                S.touches[id] = tr
            end
            if tr.role == "look" then
                lookDX = lookDX + ts.delta.x
                lookDY = lookDY + ts.delta.y
            elseif tr.role == "move" then
                local radius = math.max(40.0, math.min(W, H) * 0.12)
                S.joy.x = clamp((px - tr.sx) / radius, -1.0, 1.0)
                S.joy.y = clamp((py - tr.sy) / radius, -1.0, 1.0)
                joyActive = true
            end
        end
    end
    for id, _ in pairs(S.touches) do
        if not seen[id] then
            S.touches[id] = nil
        end
    end
    if not joyActive then
        S.joy.x, S.joy.y = 0.0, 0.0
    end
    S.joy.active = joyActive
    return n > 0, lookDX, lookDY
end

---@param dt number
---@param paused boolean
function Controls.Update(dt, paused)
    local W, H = graphics:GetWidth(), graphics:GetHeight()
    if input:GetKeyPress(KEY_R) then
        Controls.ResumeCruise()
    end
    if input:GetKeyPress(KEY_P) then
        Controls.Replay()
    end

    -- 重播淡出 → 跳回开场 → 淡入
    if S.fadeDir ~= 0.0 then
        S.fade = clamp(S.fade + S.fadeDir * dt / 0.35, 0.0, 1.0)
        if S.fadeDir > 0.0 and S.fade >= 1.0 then
            if S.pendingReplay then
                doReplay()
                S.pendingReplay = false
            end
            S.fadeDir = -1.0
        elseif S.fadeDir < 0.0 and S.fade <= 0.0 then
            S.fadeDir = 0.0
        end
    end

    local touching, tdx, tdy = updateTouches(W, H)

    -- 鼠标（有触点时忽略，避免触屏模拟出的鼠标事件重复处理）
    local mp = input:GetMousePosition()
    if S.lastMouse and (mp.x ~= S.lastMouse.x or mp.y ~= S.lastMouse.y) then
        S.idleMouse = 0.0
    else
        S.idleMouse = S.idleMouse + dt
    end
    S.lastMouse = IntVector2(mp.x, mp.y)
    if not touching then
        local down = input:GetMouseButtonDown(MOUSEB_LEFT) or input:GetMouseButtonDown(MOUSEB_RIGHT)
        local press = input:GetMouseButtonPress(MOUSEB_LEFT) or input:GetMouseButtonPress(MOUSEB_RIGHT)
        if press and not isOverUI(mp.x, mp.y) then
            S.dragging = true
            takeOver()
        end
        if not down then
            S.dragging = false
        end
        if S.dragging then
            local mm = input:GetMouseMove()
            S.yaw = S.yaw + mm.x * DRAG_SENS
            S.pitch = clamp(S.pitch - mm.y * DRAG_SENS, -86.0, 86.0)
        end
    end
    if touching and (math.abs(tdx) + math.abs(tdy) > 0.0) then
        takeOver()
        S.yaw = S.yaw + tdx * TOUCH_SENS
        S.pitch = clamp(S.pitch - tdy * TOUCH_SENS, -86.0, 86.0)
    end
    if S.joy.active or anyMoveKey() then
        takeOver()
    end

    if S.mode == "manual" then
        local fwd, right = basisFrom(S.yaw, S.pitch)
        local mv = Vector3(0, 0, 0)
        local f = (input:GetKeyDown(KEY_W) and 1 or 0) - (input:GetKeyDown(KEY_S) and 1 or 0) - S.joy.y
        local r = (input:GetKeyDown(KEY_D) and 1 or 0) - (input:GetKeyDown(KEY_A) and 1 or 0) + S.joy.x
        local u = (input:GetKeyDown(KEY_E) and 1 or 0) - (input:GetKeyDown(KEY_Q) and 1 or 0)
        mv = fwd * f + right * r + Vector3(0, 1, 0) * u
        local len = mv:Length()
        if len > 1.0 then
            mv = mv * (1.0 / len)
        end
        local speed = FLY_SPEED
        if input:GetKeyDown(KEY_LSHIFT) or input:GetKeyDown(KEY_RSHIFT) then
            speed = speed * BOOST
        end
        local target = mv * speed
        local k = 1.0 - math.exp(-dt * 6.0)
        S.vel = S.vel + (target - S.vel) * k
        S.pos = S.pos + S.vel * dt
        S.roll = S.roll * math.exp(-dt * 4.0)
        return
    end

    -- 巡航
    if not paused then
        S.cruiseT = S.cruiseT + dt
    end
    local p, yaw, pitch, roll = CameraPath.Evaluate(S.cruiseT)
    p = p + S.cruiseOff
    -- 鼠标微调：根据指针相对屏幕中心的位置；停止移动 3 s 后回正
    if not touching and S.idleMouse < 3.0 and W > 0 and H > 0 then
        S.fineTY = clamp((mp.x / W) * 2.0 - 1.0, -1.0, 1.0) * FINE_YAW
        S.fineTP = -clamp((mp.y / H) * 2.0 - 1.0, -1.0, 1.0) * FINE_PITCH
    else
        S.fineTY, S.fineTP = 0.0, 0.0
    end
    local kf = 1.0 - math.exp(-dt * 2.5)
    S.fineYaw = S.fineYaw + (S.fineTY - S.fineYaw) * kf
    S.finePitch = S.finePitch + (S.fineTP - S.finePitch) * kf
    if S.blend < 1.0 and S.blendFrom then
        S.blend = math.min(1.0, S.blend + dt / 2.2)
        local b = S.blend * S.blend * (3.0 - 2.0 * S.blend)
        local from = S.blendFrom
        -- 偏航按最短方向插值
        local dy = yaw - from.yaw
        dy = dy - 360.0 * math.floor((dy + 180.0) / 360.0)
        p = from.pos + (p - from.pos) * b
        yaw = (yaw - dy) + dy * b
        pitch = from.pitch + (pitch - from.pitch) * b
        roll = from.roll + (roll - from.roll) * b
    end
    S.pos = p
    S.yaw = yaw
    S.pitch = pitch
    S.roll = roll
end

-- 当前渲染用位姿（巡航时叠加微调）
function Controls.Pose()
    if S.mode == "cruise" then
        return S.pos, S.yaw + S.fineYaw, clamp(S.pitch + S.finePitch, -88.0, 88.0), S.roll
    end
    return S.pos, S.yaw, S.pitch, S.roll
end

function Controls.Fade()
    return S.fade
end

return Controls
