// ============================================================================
// Abyss · 辉光降采样（13 次采样，首级带软阈值与 Karis 平均，抑制萤火虫噪点）
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D src_tex : filter_linear, repeat_disable;
uniform vec4 u_bloom;    // x: 是否预过滤；y: 阈值；z: 软膝；w: 采样跨度（源纹素倍数）
uniform vec4 u_src;      // xy: 源纹素尺寸

varying vec2 v_ndc;

void vertex() {
    v_ndc = VERTEX.xz * 2.0;
    POSITION = vec4(v_ndc, 0.0, 1.0);
}

vec3 tap(vec2 uv) {
    return max(texture(src_tex, uv).rgb, vec3(0.0));
}

float karis(vec3 c) {
    return 1.0 / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722)));
}

vec3 prefilter(vec3 c) {
    float br = max(c.r, max(c.g, c.b));
    float knee = u_bloom.y * u_bloom.z;
    float soft = clamp(br - u_bloom.y + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contrib = max(soft, br - u_bloom.y) / max(br, 1e-4);
    return c * contrib;
}

void fragment() {
    vec2 uv = FRAGCOORD.xy / VIEWPORT_SIZE;
    vec2 t = u_src.xy * u_bloom.w;
    vec3 sA = tap(uv + t * vec2(-2.0, -2.0));
    vec3 sB = tap(uv + t * vec2(0.0, -2.0));
    vec3 sC = tap(uv + t * vec2(2.0, -2.0));
    vec3 sD = tap(uv + t * vec2(-1.0, -1.0));
    vec3 sE = tap(uv + t * vec2(1.0, -1.0));
    vec3 sF = tap(uv + t * vec2(-2.0, 0.0));
    vec3 sG = tap(uv);
    vec3 sH = tap(uv + t * vec2(2.0, 0.0));
    vec3 sI = tap(uv + t * vec2(-1.0, 1.0));
    vec3 sJ = tap(uv + t * vec2(1.0, 1.0));
    vec3 sK = tap(uv + t * vec2(-2.0, 2.0));
    vec3 sL = tap(uv + t * vec2(0.0, 2.0));
    vec3 sM = tap(uv + t * vec2(2.0, 2.0));
    vec3 g0 = (sD + sE + sI + sJ) * 0.25;
    vec3 g1 = (sA + sB + sF + sG) * 0.25;
    vec3 g2 = (sB + sC + sG + sH) * 0.25;
    vec3 g3 = (sF + sG + sK + sL) * 0.25;
    vec3 g4 = (sG + sH + sL + sM) * 0.25;
    vec3 o;
    if (u_bloom.x > 0.5) {
        g0 = prefilter(g0);
        g1 = prefilter(g1);
        g2 = prefilter(g2);
        g3 = prefilter(g3);
        g4 = prefilter(g4);
        float k0 = karis(g0) * 0.5;
        float k1 = karis(g1) * 0.125;
        float k2 = karis(g2) * 0.125;
        float k3 = karis(g3) * 0.125;
        float k4 = karis(g4) * 0.125;
        o = (g0 * k0 + g1 * k1 + g2 * k2 + g3 * k3 + g4 * k4) / (k0 + k1 + k2 + k3 + k4);
    } else {
        o = g0 * 0.5 + (g1 + g2 + g3 + g4) * 0.125;
    }
    ALBEDO = o;
    ALPHA = 1.0;
}
