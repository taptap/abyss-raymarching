-- ============================================================================
-- ABYSS · 无限延伸的暗黑工业分形巨构深渊
-- 所有可见结构都由全屏 SurfaceShader 的光线步进 + SDF 实时生成（场景里没有任何网格拼装）。
-- 渲染：Abyss/Pipeline.lua；镜头：Abyss/CameraPath.lua + Abyss/Controls.lua；机构：Abyss/Mechanics.lua
-- 录制：ENTRY=record.lua 时 RECORD 表存在，按固定帧率逐帧渲染并把 PNG 写到磁盘。
-- ============================================================================

local Pipeline = require("Abyss.Pipeline")
local Mechanics = require("Abyss.Mechanics")
local CameraPath = require("Abyss.CameraPath")
local Palettes = require("Abyss.Palettes")
local Controls = require("Abyss.Controls")

---@type table
local pipeline_
local HUD = nil
local animT_ = 0.0
local paused_ = false
local palIdx_ = 1
local palFrom_ = nil
local palBlend_ = 1.0
---@type table|nil
local prevCam_ = nil
local dtAvg_ = 1.0 / 60.0
local slowTimer_ = 0.0
local fastTimer_ = 0.0
local sinceLevel_ = 0.0
local logTimer_ = 0.0
local wallClock_ = 0.0

local DEPTH_DATUM = 2310.0
local VFOV = 56.0

-- 光照强度（与配色无关的部分）
local LIGHT = {
    furnI = 9000.0,     -- 锻炉照明
    slotI = 12.0,       -- 能量槽照明
    lampI = 1.0,        -- 局部灯照明倍率
    ambient = 1.0,
    emberE = 16.0,      -- 炉火自发光亮度
    slotE = 6.0,        -- 能量槽自发光
    lampE = 14.0,       -- 灯具自发光
    volGain = 0.03,     -- 体积光增益
    maxSteps = 170,
    fogBlend = 70.0,
    volume = 1.0,
    maxDist = 700.0,
}

local POST = {
    exposure = 1.8,
    bloom = 0.055,
    bloomThreshold = 1.4,
    chroma = 0.0032,
    vignette = 0.45,
    grain = 0.03,
    saturation = 1.0,
    sharpen = 0.32,
    lift = 0.006,
    taaBase = 0.1,
    taaMotion = 0.2,
}

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerp3(a, b, t)
    return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t) }
end

-- 当前配色（切换时 1.2 s 平滑过渡）
local function currentLook()
    local to = Palettes[palIdx_]
    local from = palFrom_ or to
    local t = palBlend_ * palBlend_ * (3.0 - 2.0 * palBlend_)
    return {
        fogNear = lerp3(from.fogNear, to.fogNear, t),
        fogFar = lerp3(from.fogFar, to.fogFar, t),
        furn = lerp3(from.furn, to.furn, t),
        slot = lerp3(from.slot, to.slot, t),
        lamp = lerp3(from.lamp, to.lamp, t),
        density = lerp(from.density, to.density, t),
        saturation = lerp(from.saturation, to.saturation, t),
        exposure = lerp(from.exposure, to.exposure, t),
        furnI = LIGHT.furnI,
        slotI = LIGHT.slotI,
        lampI = LIGHT.lampI,
        ambient = LIGHT.ambient,
        emberE = LIGHT.emberE,
        slotE = LIGHT.slotE,
        lampE = LIGHT.lampE,
        volGain = LIGHT.volGain,
        maxSteps = RECORD and 220 or LIGHT.maxSteps,
        volSamples = RECORD and 30 or 14,
        shadowSteps = RECORD and 44 or 30,
        fogBlend = LIGHT.fogBlend,
        volume = LIGHT.volume,
        maxDist = LIGHT.maxDist,
    }
end

-- 相机：偏航/俯仰/横滚 → 基向量；位置按世界周期回绕（着色器里保持小坐标，精度足够）
local function makeCamera(pos, yawDeg, pitchDeg, rollDeg, aspect)
    local y, p, r = math.rad(yawDeg), math.rad(pitchDeg), math.rad(rollDeg)
    local fwd = Vector3(math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p))
    local right = Vector3(math.cos(y), 0.0, -math.sin(y))
    local up = fwd:CrossProduct(right)
    local cr, sr = math.cos(r), math.sin(r)
    local right2 = right * cr + up * sr
    local up2 = up * cr - right * sr
    local tanY = math.tan(math.rad(VFOV * 0.5))
    local tanX = tanY * aspect
    if aspect < 1.0 then
        tanX = math.tan(math.rad(36.0))
        tanY = tanX / aspect
    end
    local wrap = Vector3(480.0 * math.floor(pos.x / 480.0 + 0.5), 300.0 * math.floor(pos.y / 300.0 + 0.5),
        240.0 * math.floor(pos.z / 240.0 + 0.5))
    return { pos = pos - wrap, world = pos, wrap = wrap, right = right2, up = up2, fwd = fwd, tanX = tanX, tanY = tanY }
end

-- 上一帧相机换到当前帧的回绕坐标系
local function prevInFrame(prev, cam)
    if not prev then
        return nil
    end
    return { pos = prev.world - cam.wrap, right = prev.right, up = prev.up, fwd = prev.fwd }
end

local function radiationAt(world, anim, t)
    local q = Vector3(world.x - 240.0 * math.floor(world.x / 240.0 + 0.5), world.y - 300.0 * math.floor(world.y / 300.0 + 0.5),
        world.z - 240.0 * math.floor(world.z / 240.0 + 0.5))
    local d = (q - Vector3(0.0, anim.furnY, 0.0)):Length()
    local noise = 0.04 * math.sin(t * 7.1) + 0.03 * math.sin(t * 13.7 + 1.0)
    return 0.09 + 60.0 / (1.0 + (d / 14.0) ^ 2) * (1.0 + noise)
end

local function postFor(look, fade)
    return {
        exposure = POST.exposure * look.exposure,
        bloom = POST.bloom,
        bloomThreshold = POST.bloomThreshold,
        chroma = POST.chroma,
        vignette = POST.vignette,
        grain = POST.grain,
        saturation = POST.saturation * look.saturation,
        sharpen = POST.sharpen,
        lift = POST.lift,
        taaBase = POST.taaBase,
        taaMotion = POST.taaMotion,
        fade = fade,
    }
end

-- ---------------------------------------------------------------------------
-- 录制模式
-- ---------------------------------------------------------------------------
local rec_ = { step = 0, pending = nil, started = 0.0 }

local function recordStep()
    local R = RECORD
    rec_.step = rec_.step + 1
    if rec_.pending then
        local img = pipeline_.final.texture:GetImage()
        local name = string.format("%s/f%05d.png", R.out, rec_.pending + (R.indexOffset or 0))
        if img then
            if R.flipY then
                img:FlipVertical()
            end
            local ok = img:SavePNG(name)
            if not ok then
                print("[Abyss][REC] SavePNG failed: " .. name)
            end
        else
            print("[Abyss][REC] readback failed for " .. name)
        end
        if rec_.pending % 10 == 0 or rec_.pending == R.frames - 1 then
            print(string.format("[Abyss][REC] saved frame %d / %d  (wall %.1f s)", rec_.pending, R.frames, wallClock_ - rec_.started))
        end
        if rec_.pending >= R.frames - 1 then
            print("[Abyss][REC] done")
            engine:Exit()
            rec_.pending = nil
            return
        end
        rec_.pending = nil
    end
    local S = R.sub or 1
    local warm = R.warm or 12
    local videoIdx, sub
    if rec_.step <= warm then
        videoIdx, sub = 0, S - 1
    else
        local k = rec_.step - warm - 1
        videoIdx = math.floor(k / S)
        sub = k % S
    end
    if videoIdx >= R.frames then
        engine:Exit()
        return
    end
    local t = R.start + videoIdx / R.fps
    if S > 1 then
        t = t + ((sub + 0.5) / S - 0.5) * (R.shutter or 0.5) / R.fps
    end
    local pos, yaw, pitch, roll = CameraPath.Evaluate(t)
    local cam = makeCamera(pos, yaw, pitch, roll, R.w / R.h)
    local anim = Mechanics.Evaluate(t)
    local look = currentLook()
    local accum = 0.0
    local prev = prevInFrame(prevCam_, cam)
    if S > 1 then
        accum = 1.0 / (sub + 1)
        prev = cam
    end
    if rec_.step == 1 then
        pipeline_:ResetHistory()
    end
    pipeline_:Render(cam, prev, anim, look, postFor(look, 0.0), t, accum)
    prevCam_ = cam
    if rec_.step > warm and sub == S - 1 then
        rec_.pending = videoIdx
    end
end

-- ---------------------------------------------------------------------------
-- 交互模式
-- ---------------------------------------------------------------------------
local function adaptResolution(dt)
    dtAvg_ = dtAvg_ + (dt - dtAvg_) * 0.08
    sinceLevel_ = sinceLevel_ + dt
    if dtAvg_ > 1.0 / 52.0 then
        slowTimer_ = slowTimer_ + dt
        fastTimer_ = 0.0
    elseif dtAvg_ < 1.0 / 66.0 then
        fastTimer_ = fastTimer_ + dt
        slowTimer_ = 0.0
    else
        slowTimer_, fastTimer_ = 0.0, 0.0
    end
    if slowTimer_ > 0.8 and sinceLevel_ > 1.5 and pipeline_.level < #pipeline_.levels then
        pipeline_:SetLevel(pipeline_.level + 1)
        slowTimer_, sinceLevel_ = 0.0, 0.0
    elseif fastTimer_ > 4.0 and sinceLevel_ > 6.0 and pipeline_.level > 1 then
        pipeline_:SetLevel(pipeline_.level - 1)
        fastTimer_, sinceLevel_ = 0.0, 0.0
    end
end

function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    wallClock_ = wallClock_ + dt
    if RECORD then
        recordStep()
        return
    end
    dt = math.min(dt, 0.1)
    Controls.Update(dt, paused_)
    if not paused_ then
        animT_ = animT_ + dt
    end
    if palBlend_ < 1.0 then
        palBlend_ = math.min(1.0, palBlend_ + dt / 1.2)
    end
    local pos, yaw, pitch, roll = Controls.Pose()
    local W, H = graphics:GetWidth(), graphics:GetHeight()
    local cam = makeCamera(pos, yaw, pitch, roll, W / math.max(H, 1))
    local anim = Mechanics.Evaluate(animT_)
    local look = currentLook()
    pipeline_:Render(cam, prevInFrame(prevCam_, cam), anim, look, postFor(look, Controls.Fade()), animT_, 0.0)
    prevCam_ = cam
    if HUD then
        HUD.Update(DEPTH_DATUM - pos.y, radiationAt(pos, anim, animT_), paused_, Palettes[palIdx_].name)
    end
    if not FIXED_LEVEL then
        adaptResolution(dt)
    end
    logTimer_ = logTimer_ + dt
    if logTimer_ > 3.0 then
        logTimer_ = 0.0
        print(string.format("[Abyss] fps %.1f  scale %.2f (%dx%d)  mode %s  t %.1f", 1.0 / dtAvg_,
            pipeline_.levels[pipeline_.level], pipeline_.rw, pipeline_.rh, Controls.state.mode, Controls.state.cruiseT))
    end
end

function Start()
    graphics.windowTitle = "ABYSS"
    if RECORD then
        print(string.format("[Abyss][REC] %dx%d @%.3f fps, %d frames from t=%.2f, sub=%d -> %s",
            RECORD.w, RECORD.h, RECORD.fps, RECORD.frames, RECORD.start, RECORD.sub or 1, RECORD.out))
        if not fileSystem:DirExists(RECORD.out) then
            print("[Abyss][REC] create dir " .. RECORD.out .. " -> " .. tostring(fileSystem:CreateDir(RECORD.out)))
        end
        pipeline_ = Pipeline.new({ recordW = RECORD.w, recordH = RECORD.h, level = 1 })
    else
        local platform = GetPlatform()
        local mobile = (platform == "Android" or platform == "iOS")
        pipeline_ = Pipeline.new({ level = START_LEVEL or (mobile and 5 or 3) })
        HUD = require("Abyss.HUD")
        HUD.Init({
            onPause = function()
                paused_ = not paused_
                print("[Abyss] paused = " .. tostring(paused_))
            end,
            onPalette = function()
                palFrom_ = currentLook()
                palBlend_ = 0.0
                palIdx_ = palIdx_ % #Palettes + 1
                print("[Abyss] palette " .. Palettes[palIdx_].name)
            end,
        })
        Controls.SetUIHitTest(HUD.IsOverUI)
        if START_TIME then
            Controls.state.cruiseT = START_TIME
            animT_ = START_TIME
        end
    end
    SubscribeToEvent("Update", "HandleUpdate")
    print("=== ABYSS started ===")
end

function Stop()
    if HUD then
        HUD.Shutdown()
    end
end
