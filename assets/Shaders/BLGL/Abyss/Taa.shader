// ============================================================================
// Abyss · TAA：子像素抖动累积 + 深度重投影 + YCoCg 方差裁剪
// 输入：当前帧（抖动后，ALPHA 为射线距离，负值=动态物体）与上一帧历史。
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform highp sampler2D cur_tex : filter_nearest, repeat_disable;
uniform sampler2D hist_tex : filter_linear, repeat_disable;
uniform vec3 u_cam_pos;
uniform vec3 u_cam_right;
uniform vec3 u_cam_up;
uniform vec3 u_cam_fwd;
uniform vec3 u_prev_pos;
uniform vec3 u_prev_right;
uniform vec3 u_prev_up;
uniform vec3 u_prev_fwd;
uniform vec4 u_proj;     // x,y: tan(半视场)；z,w: 当前抖动
uniform vec4 u_taa;      // x: 重置历史；y: 基础混合率；z: 运动时最大混合率；w: 累积模式（离线录制）

varying vec2 v_ndc;

void vertex() {
    v_ndc = VERTEX.xz * 2.0;
    POSITION = vec4(v_ndc, 0.0, 1.0);
}

vec3 toYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// 可逆的亮度压缩，减少高亮像素（炉口、灯）引起的闪烁
vec3 tmc(vec3 c) {
    return c / (1.0 + max(c.r, max(c.g, c.b)));
}

vec3 itmc(vec3 c) {
    return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4);
}

vec3 clipAABB(vec3 c, vec3 mn, vec3 mx) {
    vec3 cen = 0.5 * (mx + mn);
    vec3 ext = 0.5 * (mx - mn) + vec3(1e-5);
    vec3 v = c - cen;
    vec3 a = abs(v / ext);
    float m = max(a.x, max(a.y, a.z));
    return (m > 1.0) ? (cen + v / m) : c;
}

// 5 次采样的 Catmull-Rom 历史重采样（比双线性更锐利）
vec3 sampleHistory(vec2 uv, vec2 size) {
    vec2 sp = uv * size;
    vec2 tp1 = floor(sp - 0.5) + 0.5;
    vec2 f = sp - tp1;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 o12 = w2 / w12;
    vec2 t0 = (tp1 - 1.0) / size;
    vec2 t3 = (tp1 + 2.0) / size;
    vec2 t12 = (tp1 + o12) / size;
    vec3 r = texture(hist_tex, vec2(t12.x, t0.y)).rgb * (w12.x * w0.y);
    r += texture(hist_tex, vec2(t0.x, t12.y)).rgb * (w0.x * w12.y);
    r += texture(hist_tex, vec2(t12.x, t12.y)).rgb * (w12.x * w12.y);
    r += texture(hist_tex, vec2(t3.x, t12.y)).rgb * (w3.x * w12.y);
    r += texture(hist_tex, vec2(t12.x, t3.y)).rgb * (w12.x * w3.y);
    float ws = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(r / ws, vec3(0.0));
}

void fragment() {
    vec2 size = VIEWPORT_SIZE;
    vec2 tx = 1.0 / size;
    vec2 uv = FRAGCOORD.xy * tx;
    // 纹理 v 方向与裁剪空间 y 是否一致（GL 一致；D3D / Metal / WebGPU 相反）
    float ysgn = ((uv.y - 0.5) * v_ndc.y >= 0.0) ? 1.0 : (-1.0);

    vec4 center = texture(cur_tex, uv);
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    vec3 cmin = vec3(1e9);
    vec3 cmax = vec3(-1e9);
    float closest = 1e9;
    vec2 cOff = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 off = vec2(float(i), float(j));
            vec4 s = texture(cur_tex, uv + off * tx);
            vec3 c = toYCoCg(tmc(max(s.rgb, vec3(0.0))));
            m1 += c;
            m2 += c * c;
            cmin = min(cmin, c);
            cmax = max(cmax, c);
            float dp = abs(s.a);
            if (dp < closest) {
                closest = dp;
                cOff = off;
            }
        }
    }
    m1 *= (1.0 / 9.0);
    m2 *= (1.0 / 9.0);
    vec3 sigma = sqrt(max(m2 - m1 * m1, vec3(0.0)));
    bool dyn = center.a < 0.0;

    // 用 3x3 中最近的深度重建世界坐标，再投到上一帧相机
    vec2 ndcS = v_ndc + vec2(cOff.x * 2.0 * tx.x, cOff.y * 2.0 * tx.y * ysgn);
    vec3 dir = normalize(u_cam_fwd + ndcS.x * u_proj.x * u_cam_right + ndcS.y * u_proj.y * u_cam_up);
    vec3 P = u_cam_pos + dir * closest;
    vec3 rel = P - u_prev_pos;
    float zf = dot(rel, u_prev_fwd);
    vec2 pndc = vec2(dot(rel, u_prev_right) / (max(zf, 1e-3) * u_proj.x), dot(rel, u_prev_up) / (max(zf, 1e-3) * u_proj.y));
    vec2 vel = pndc - ndcS;
    vec2 prevNdc = v_ndc + vel;
    vec2 prevUV = vec2(prevNdc.x * 0.5 + 0.5, prevNdc.y * 0.5 * ysgn + 0.5);
    bool offscreen = prevUV.x < 0.0 || prevUV.y < 0.0 || prevUV.x > 1.0 || prevUV.y > 1.0 || zf <= 0.0;

    vec3 cc = toYCoCg(tmc(max(center.rgb, vec3(0.0))));
    vec3 hist = sampleHistory(prevUV, size);
    vec3 hc = toYCoCg(tmc(hist));
    float speedPx = length(vel * size * 0.5);
    float gam = dyn ? 0.8 : mix(1.35, 0.95, clamp(speedPx / 24.0, 0.0, 1.0));
    vec3 bmin = max(cmin, m1 - gam * sigma);
    vec3 bmax = min(cmax, m1 + gam * sigma);
    hc = clipAABB(hc, bmin, bmax);

    float alpha = mix(u_taa.y, u_taa.z, clamp(speedPx / 40.0, 0.0, 1.0));
    if (dyn) {
        alpha = max(alpha, 0.22);
    }
    if (u_taa.w > 0.0) {
        // 离线累积：同一时刻多次抖动采样，按 1/n 平均，不裁剪
        alpha = u_taa.w;
        hc = toYCoCg(tmc(hist));
    }
    if (offscreen || u_taa.x > 0.5) {
        alpha = 1.0;
    }
    float wc = alpha / (1.0 + cc.x);
    float wh = (1.0 - alpha) / (1.0 + hc.x);
    vec3 res = (cc * wc + hc * wh) / max(wc + wh, 1e-5);
    ALBEDO = max(itmc(fromYCoCg(res)), vec3(0.0));
    ALPHA = 1.0;
}
