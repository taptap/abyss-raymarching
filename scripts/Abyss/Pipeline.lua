-- 渲染管线：五个全屏 SurfaceShader pass，各自在独立小场景里渲染到纹理
--   march（RGBA16F，HDR 颜色 + 射线距离）→ taaA/taaB（历史乒乓）→ bloom1(1/4) → bloom2(1/16) → final
-- 渲染顺序由纹理首次 SetSize 的先后决定：先创建的最后渲染。所以按 final→bloom2→bloom1→taa→march 创建。
-- 所有 pass 的渲染目标都用 SURFACE_MANUALUPDATE，每帧只排队需要的那几个（TAA 只排当前写入的一张）。

local Pipeline = {}
Pipeline.__index = Pipeline

local DIR = "Shaders/BLGL/Abyss/"

local function halton(i, b)
    local f, r = 1.0, 0.0
    while i > 0 do
        f = f / b
        r = r + f * (i % b)
        i = math.floor(i / b)
    end
    return r
end

local JITTER = {}
for i = 1, 16 do
    JITTER[i] = { halton(i, 2) - 0.5, halton(i, 3) - 0.5 }
end

local function makePass(name, shader)
    local p = { name = name }
    p.scene = Scene()
    p.scene:CreateComponent("Octree")
    local camNode = p.scene:CreateChild("Cam")
    p.camera = camNode:CreateComponent("Camera")
    p.camera.nearClip = 0.1
    p.camera.farClip = 10.0
    local quad = camNode:CreateChild("Quad")
    quad.position = Vector3(0.0, 0.0, 1.0)
    quad.rotation = Quaternion(-90.0, Vector3(1.0, 0.0, 0.0))
    local sm = quad:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", "Models/Plane.mdl"))
    sm.castShadows = false
    p.material = Material:new()
    local ok = p.material:SetSurfaceShader(DIR .. shader)
    print(string.format("[Abyss] pass %-7s shader %s -> %s", name, shader, tostring(ok)))
    sm:SetMaterial(p.material)
    p.viewport = Viewport:new(p.scene, p.camera)
    p.viewport:SetRenderPath(cache:GetResource("XMLFile", "RenderPaths/Forward.xml"))
    return p
end

local function attachTarget(p, w, h, format)
    if not p.texture then
        p.texture = Texture2D:new()
        p.texture:SetNumLevels(1)
    end
    assert(p.texture:SetSize(w, h, format, TEXTURE_RENDERTARGET), "render target " .. p.name)
    p.texture:SetFilterMode(FILTER_BILINEAR)
    p.texture:SetAddressMode(COORD_U, ADDRESS_CLAMP)
    p.texture:SetAddressMode(COORD_V, ADDRESS_CLAMP)
    p.surface = p.texture:GetRenderSurface()
    p.surface:SetViewport(0, p.viewport)
    p.surface:SetUpdateMode(SURFACE_MANUALUPDATE)
    p.w, p.h = w, h
end

local function setF(m, name, v)
    m:SetShaderParameter(name, Variant(v))
end

local function setV3(m, name, v)
    m:SetShaderParameter(name, Variant(v))
end

local function setV4(m, name, x, y, z, w)
    m:SetShaderParameter(name, Variant(Vector4(x, y, z, w)))
end

local function setRGB(m, name, c)
    m:SetShaderParameter(name, Variant(Vector3(c[1], c[2], c[3])))
end

---@param opts table { recordW?, recordH?, level? }
function Pipeline.new(opts)
    local self = setmetatable({}, Pipeline)
    opts = opts or {}
    self.opts = opts
    self.record = opts.recordW ~= nil
    self.levels = { 1.0, 0.85, 0.72, 0.6, 0.5, 0.42, 0.35 }
    self.level = opts.level or 3
    self.frame = 0
    self.reset = true
    self.f16 = Graphics:GetRGBAFloat16Format()
    -- 创建顺序 = 渲染顺序的逆序
    if self.record then
        self.final = makePass("final", "Final.shader")
    end
    self.bloom2 = makePass("bloom2", "Bloom.shader")
    self.bloom1 = makePass("bloom1", "Bloom.shader")
    self.taaA = makePass("taaA", "Taa.shader")
    self.taaB = makePass("taaB", "Taa.shader")
    self.march = makePass("march", "March.shader")
    if not self.record then
        self.final = makePass("final", "Final.shader")
        renderer:SetViewport(0, self.final.viewport)
    end
    self:Resize()
    return self
end

function Pipeline:OutputSize()
    if self.record then
        return self.opts.recordW, self.opts.recordH
    end
    return graphics:GetWidth(), graphics:GetHeight()
end

function Pipeline:Resize()
    local W, H = self:OutputSize()
    local s = self.levels[self.level]
    local rw = math.max(64, math.floor(W * s + 0.5))
    local rh = math.max(36, math.floor(H * s + 0.5))
    self.outW, self.outH = W, H
    self.rw, self.rh = rw, rh
    local b1w, b1h = math.max(8, math.floor(rw / 4)), math.max(8, math.floor(rh / 4))
    local b2w, b2h = math.max(4, math.floor(b1w / 4)), math.max(4, math.floor(b1h / 4))
    if self.record then
        attachTarget(self.final, W, H, Graphics:GetRGBAFormat())
    end
    attachTarget(self.bloom2, b2w, b2h, self.f16)
    attachTarget(self.bloom1, b1w, b1h, self.f16)
    attachTarget(self.taaA, rw, rh, self.f16)
    attachTarget(self.taaB, rw, rh, self.f16)
    attachTarget(self.march, rw, rh, self.f16)
    self.reset = true
    print(string.format("[Abyss] resize output %dx%d render %dx%d (scale %.2f) bloom %dx%d / %dx%d",
        W, H, rw, rh, s, b1w, b1h, b2w, b2h))
end

function Pipeline:SetLevel(level)
    level = math.max(1, math.min(#self.levels, level))
    if level ~= self.level then
        self.level = level
        self:Resize()
    end
end

-- 相机基向量（Lua 侧已按世界周期回绕过的位置）
---@param cam table { pos, right, up, fwd, tanX, tanY }
---@param prev table|nil 上一帧相机（同一回绕坐标系）
---@param anim table Mechanics.Evaluate 的结果
---@param look table 配色与强度
---@param post table 后期参数
function Pipeline:Render(cam, prev, anim, look, post, timeNow, accumAlpha)
    self.frame = self.frame + 1
    local W, H = self:OutputSize()
    if (not self.record) and (W ~= self.outW or H ~= self.outH) then
        self:Resize()
    end
    local rw, rh = self.rw, self.rh
    local j = JITTER[(self.frame % 16) + 1]
    local jx, jy = j[1] * 2.0 / rw, j[2] * 2.0 / rh
    local pixAng = 2.0 * cam.tanY / rh

    -- ---- march ----
    local m = self.march.material
    setV3(m, "u_cam_pos", cam.pos)
    setV3(m, "u_cam_right", cam.right)
    setV3(m, "u_cam_up", cam.up)
    setV3(m, "u_cam_fwd", cam.fwd)
    setV4(m, "u_proj", cam.tanX, cam.tanY, jx, jy)
    setV4(m, "u_frame", timeNow, self.frame % 4096, pixAng, look.maxSteps or 160)
    setV4(m, "u_furn", anim.furnY, anim.blade, 1.0, anim.flicker)
    setV4(m, "u_frot", anim.cx, anim.sx, anim.cz, anim.sz)
    m:SetShaderParameter("u_pist0", Variant(anim.pist[1]))
    m:SetShaderParameter("u_pist1", Variant(anim.pist[2]))
    m:SetShaderParameter("u_pist2", Variant(anim.pist[3]))
    m:SetShaderParameter("u_pist3", Variant(anim.pist[4]))
    setV4(m, "u_mech", anim.trainA, anim.trainB, anim.cabY, anim.cwY)
    setRGB(m, "u_fog_near", look.fogNear)
    setRGB(m, "u_fog_far", look.fogFar)
    setV4(m, "u_fogp", look.density, look.fogBlend or 140.0, look.volume or 1.0, look.maxDist or 700.0)
    setRGB(m, "u_col_furn", look.furn)
    setRGB(m, "u_col_slot", look.slot)
    setRGB(m, "u_col_lamp", look.lamp)
    setV4(m, "u_light", look.furnI, look.slotI, look.lampI, look.ambient)
    setV4(m, "u_emit", look.emberE, look.slotE, look.lampE, look.volGain)
    setV4(m, "u_quality", look.volSamples or 14, look.shadowSteps or 30, 0.0, 0.0)
    local dbg = DEBUG_VIEW or { 0, 0, 0, 0 }
    setV4(m, "u_debug", dbg[1], dbg[2], dbg[3], dbg[4])

    -- ---- TAA（乒乓）----
    local cur = (self.frame % 2 == 0) and self.taaA or self.taaB
    local hist = (self.frame % 2 == 0) and self.taaB or self.taaA
    local t = cur.material
    t:SetSurfaceTexture("cur_tex", self.march.texture)
    t:SetSurfaceTexture("hist_tex", hist.texture)
    setV3(t, "u_cam_pos", cam.pos)
    setV3(t, "u_cam_right", cam.right)
    setV3(t, "u_cam_up", cam.up)
    setV3(t, "u_cam_fwd", cam.fwd)
    local pv = prev or cam
    setV3(t, "u_prev_pos", pv.pos)
    setV3(t, "u_prev_right", pv.right)
    setV3(t, "u_prev_up", pv.up)
    setV3(t, "u_prev_fwd", pv.fwd)
    setV4(t, "u_proj", cam.tanX, cam.tanY, jx, jy)
    setV4(t, "u_taa", self.reset and 1.0 or 0.0, post.taaBase or 0.1, post.taaMotion or 0.22, accumAlpha or 0.0)
    self.reset = false

    -- ---- 辉光 ----
    local b1 = self.bloom1.material
    b1:SetSurfaceTexture("src_tex", cur.texture)
    setV4(b1, "u_bloom", 1.0, post.bloomThreshold or 1.2, 0.6, 2.0)
    setV4(b1, "u_src", 1.0 / rw, 1.0 / rh, 0.0, 0.0)
    local b2 = self.bloom2.material
    b2:SetSurfaceTexture("src_tex", self.bloom1.texture)
    setV4(b2, "u_bloom", 0.0, 0.0, 0.5, 2.0)
    setV4(b2, "u_src", 1.0 / self.bloom1.w, 1.0 / self.bloom1.h, 0.0, 0.0)

    -- ---- 合成 ----
    local f = self.final.material
    f:SetSurfaceTexture("taa_tex", cur.texture)
    f:SetSurfaceTexture("bloom1_tex", self.bloom1.texture)
    f:SetSurfaceTexture("bloom2_tex", self.bloom2.texture)
    setV4(f, "u_post", post.exposure, post.bloom, post.chroma, post.vignette)
    setV4(f, "u_post2", post.grain, post.saturation, post.fade or 0.0, timeNow)
    setV4(f, "u_post3", post.sharpen, post.lift, W / H, self.frame % 4096)
    setV4(f, "u_src", 1.0 / rw, 1.0 / rh, 1.0 / self.bloom1.w, 1.0 / self.bloom1.h)

    self.march.surface:QueueUpdate()
    cur.surface:QueueUpdate()
    self.bloom1.surface:QueueUpdate()
    self.bloom2.surface:QueueUpdate()
    if self.record then
        self.final.surface:QueueUpdate()
    end
end

function Pipeline:ResetHistory()
    self.reset = true
end

return Pipeline
