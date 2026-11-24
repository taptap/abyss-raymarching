// ============================================================================
// Abyss · 最终合成：轻微色散、锐化、辉光、曝光、ACES Filmic、胶片暗角、颗粒、抖动、sRGB 编码
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D taa_tex : filter_linear, repeat_disable;
uniform sampler2D bloom1_tex : filter_linear, repeat_disable;
uniform sampler2D bloom2_tex : filter_linear, repeat_disable;
uniform vec4 u_post;     // x: 曝光；y: 辉光强度；z: 色散；w: 暗角
uniform vec4 u_post2;    // x: 颗粒；y: 饱和度；z: 淡出（0..1）；w: 时间
uniform vec4 u_post3;    // x: 锐化；y: 黑位抬升；z: 宽高比；w: 帧号
uniform vec4 u_src;      // xy: TAA 纹素；zw: bloom1 纹素

varying vec2 v_ndc;

void vertex() {
    v_ndc = VERTEX.xz * 2.0;
    POSITION = vec4(v_ndc, 0.0, 1.0);
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 rrtOdtFit(vec3 v) {
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

// Stephen Hill 的 ACES 拟合（含 sRGB→AP1 输入矩阵与输出矩阵）
vec3 acesFitted(vec3 c) {
    vec3 i = vec3(dot(c, vec3(0.59719, 0.35458, 0.04823)),
                  dot(c, vec3(0.07600, 0.90834, 0.01566)),
                  dot(c, vec3(0.02840, 0.13383, 0.83777)));
    vec3 r = rrtOdtFit(i);
    vec3 o = vec3(dot(r, vec3(1.60475, -0.53108, -0.07367)),
                  dot(r, vec3(-0.10208, 1.10813, -0.00605)),
                  dot(r, vec3(-0.00327, -0.07276, 1.07602)));
    return clamp(o, 0.0, 1.0);
}

float toSrgb(float x) {
    return (x <= 0.0031308) ? (x * 12.92) : (1.055 * pow(x, 1.0 / 2.4) - 0.055);
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 bloomTent1(vec2 uv, vec2 t) {
    vec3 s = texture(bloom1_tex, uv).rgb * 4.0;
    s += (texture(bloom1_tex, uv + vec2(t.x, 0.0)).rgb + texture(bloom1_tex, uv - vec2(t.x, 0.0)).rgb
        + texture(bloom1_tex, uv + vec2(0.0, t.y)).rgb + texture(bloom1_tex, uv - vec2(0.0, t.y)).rgb) * 2.0;
    s += texture(bloom1_tex, uv + t).rgb + texture(bloom1_tex, uv - t).rgb
        + texture(bloom1_tex, uv + vec2(t.x, -t.y)).rgb + texture(bloom1_tex, uv + vec2(-t.x, t.y)).rgb;
    return s * (1.0 / 16.0);
}

vec3 bloomTent2(vec2 uv, vec2 t) {
    vec3 s = texture(bloom2_tex, uv).rgb * 4.0;
    s += (texture(bloom2_tex, uv + vec2(t.x, 0.0)).rgb + texture(bloom2_tex, uv - vec2(t.x, 0.0)).rgb
        + texture(bloom2_tex, uv + vec2(0.0, t.y)).rgb + texture(bloom2_tex, uv - vec2(0.0, t.y)).rgb) * 2.0;
    s += texture(bloom2_tex, uv + t).rgb + texture(bloom2_tex, uv - t).rgb
        + texture(bloom2_tex, uv + vec2(t.x, -t.y)).rgb + texture(bloom2_tex, uv + vec2(-t.x, t.y)).rgb;
    return s * (1.0 / 16.0);
}

void fragment() {
    vec2 uv = FRAGCOORD.xy / VIEWPORT_SIZE;
    vec2 t = u_src.xy;
    // 径向色散：越靠边越明显，最大约 1.5 个像素
    vec2 d = uv - 0.5;
    float r2 = dot(d * vec2(u_post3.z, 1.0), d * vec2(u_post3.z, 1.0));
    vec2 ca = d * (u_post.z * (0.25 + r2));
    vec3 c = vec3(0.0);
    c.r = texture(taa_tex, uv + ca).r;
    c.g = texture(taa_tex, uv).g;
    c.b = texture(taa_tex, uv - ca).b;
    // 亮度锐化（抵消 TAA 的轻微模糊，保留金属纹理）
    vec3 nb = texture(taa_tex, uv + vec2(t.x, 0.0)).rgb + texture(taa_tex, uv - vec2(t.x, 0.0)).rgb
        + texture(taa_tex, uv + vec2(0.0, t.y)).rgb + texture(taa_tex, uv - vec2(0.0, t.y)).rgb;
    float lc = luma(c);
    float ln = luma(nb) * 0.25;
    float lcc = lc / (1.0 + lc);
    float lnn = ln / (1.0 + ln);
    float sharpL = clamp(lcc + (lcc - lnn) * u_post3.x, 0.0, 0.999);
    float target = sharpL / (1.0 - sharpL);
    c *= (lc > 1e-5) ? clamp(target / lc, 0.5, 2.0) : 1.0;
    // 辉光
    vec3 bl = bloomTent1(uv, u_src.zw) * 0.55 + bloomTent2(uv, u_src.zw * 4.0) * 0.45;
    c += bl * u_post.y;
    c *= u_post.x;
    float l = luma(c);
    c = max(mix(vec3(l), c, u_post2.y), vec3(0.0));
    c = acesFitted(c);
    // 胶片暗角（超宽屏主要压两侧）
    float rv = length(v_ndc * vec2(0.86, 1.0));
    c *= 1.0 - u_post.w * smoothstep(0.35, 1.5, rv);
    c = c * (1.0 - u_post3.y) + u_post3.y;
    c *= 1.0 - u_post2.z;
    vec3 o = vec3(toSrgb(c.r), toSrgb(c.g), toSrgb(c.b));
    // 颗粒（暗部更明显）+ 三角分布抖动去色带
    vec2 gp = FRAGCOORD.xy + vec2(mod(u_post3.w, 97.0) * 17.0, mod(u_post3.w, 89.0) * 13.0);
    float n1 = hash12(gp);
    float n2 = hash12(gp + 31.7);
    float grain = (n1 - 0.5) * u_post2.x * (1.0 - 0.7 * luma(o));
    o += grain + (n1 + n2 - 1.0) / 255.0;
    ALBEDO = clamp(o, 0.0, 1.0);
    ALPHA = 1.0;
}

