// ============================================================================
// Abyss · 主光线步进 pass
// 全屏四边形：顶点阶段直接写裁剪坐标；片元阶段按相机基向量生成射线，
// 步进 SDF 场景，输出 HDR 颜色（未色调映射）与射线距离（ALPHA，动态物体取负值，供 TAA 重投影）。
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform vec3 u_cam_pos;
uniform vec3 u_cam_right;
uniform vec3 u_cam_up;
uniform vec3 u_cam_fwd;
uniform vec4 u_proj;        // x,y: tan(半视场)；z,w: 子像素抖动（NDC）
uniform vec4 u_frame;       // x: 动画时间；y: 帧号；z: 每像素角度；w: 最大步数
uniform vec4 u_furn;        // x: 锻炉中心高度；y: 叶片角；z: 体积光强度；w: 炉火闪动
uniform vec4 u_frot;        // 锻炉倾斜：cos/sin(绕 X)，cos/sin(绕 Z)
uniform vec4 u_pist0;
uniform vec4 u_pist1;
uniform vec4 u_pist2;
uniform vec4 u_pist3;
uniform vec4 u_mech;        // x,y: 两列货车车头 x；z: 升降舱高度；w: 配重高度
uniform vec3 u_fog_near;
uniform vec3 u_fog_far;
uniform vec4 u_fogp;        // x: 雾密度；y: 近→远色过渡距离；z: 体积光增益；w: 最远距离
uniform vec3 u_col_furn;
uniform vec3 u_col_slot;
uniform vec3 u_col_lamp;
uniform vec4 u_light;       // x: 锻炉；y: 能量槽；z: 灯；w: 环境光
uniform vec4 u_emit;        // 自发光：x 炉火；y 能量槽；z 灯；w 体积光增益
uniform vec4 u_quality;     // x: 体积光采样数；y: 阴影步数
uniform vec4 u_debug;       // 开发用：x>0 关雾与体积光；y=1 法线 / 2 材质 / 3 步数 / 4 AO

#include "Common.shaderinc"
#include "Scene.shaderinc"
#include "Shade.shaderinc"

varying vec2 v_ndc;

void vertex() {
    v_ndc = VERTEX.xz * 2.0;
    POSITION = vec4(v_ndc, 0.0, 1.0);
}

// 青色光带：最近两层环廊檐梁上的发光条（近似线光源）
vec3 slotLights(vec3 q, vec3 n, vec3 v, vec3 diffCol, vec3 F0, float a, vec3 T, float aniso) {
    vec3 sum = vec3(0.0);
    float r = length(q.xz);
    if (r < 30.0) {
        return sum;
    }
    vec2 dir = q.xz / r;
    float lv0 = floor((q.y + 0.66) / LVL);
    for (int k = 0; k < 2; k++) {
        float lv = lv0 + float(k);
        float ry = LVL * lv - 0.66;
        vec3 c = vec3(dir.x * 56.45, ry, dir.y * 56.45);
        vec3 L = c - q;
        float d = length(L);
        vec3 l = L / max(d, 1e-3);
        float lvIdx = mod(lv, 25.0);
        float lvl = (hash11(lvIdx + 3.1) > 0.55) ? 1.0 : 0.05;
        float att = u_light.y * lvl / (d * (d + 0.6) + 0.25);
        sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
    }
    return sum * u_col_slot;
}

// 环廊檐下灯（每层每 15° 一盏，朝下照）与升降塔工作灯：取最近的几盏，解析计算
vec3 practicalLights(vec3 q, vec3 n, vec3 v, vec3 diffCol, vec3 F0, float a, vec3 T, float aniso) {
    vec3 sum = vec3(0.0);
    float r = length(q.xz);
    if (r > 44.0) {
        float seg = TAU / 24.0;
        float ang = atan(q.x, q.z);
        float a0 = round((ang + TAU / 48.0) / seg) * seg - TAU / 48.0;
        vec2 lxz = vec2(sin(a0), cos(a0)) * 57.4;
        float lv0 = floor(q.y / LVL);
        for (int k = 0; k < 2; k++) {
            float ly = LVL * (lv0 + float(k)) - 0.55;
            vec3 L = vec3(lxz.x, ly, lxz.y) - q;
            float d2 = dot(L, L);
            if (d2 < 256.0) {
                vec3 l = L * inversesqrt(d2);
                float cone = smoothstep(-0.15, 0.55, l.y);
                float att = u_light.z * 110.0 * cone / (d2 + 0.6) * (1.0 - smoothstep(100.0, 256.0, d2));
                sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
            }
        }
    }
    vec2 t2 = q.xz - TWR;
    if (max(abs(t2.x), abs(t2.y)) < 26.0) {
        float lyc = round((q.y - 6.0) / 12.0) * 12.0 + 6.0;
        float sx = (t2.x > 0.0) ? 2.98 : (-2.98);
        vec3 L = vec3(TWR.x + sx, lyc, TWR.y - 2.98) - q;
        float d2 = dot(L, L);
        vec3 l = L * inversesqrt(d2);
        float att = u_light.z * 150.0 / (d2 + 0.8) * (1.0 - smoothstep(250.0, 600.0, d2));
        sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
    }
    return sum * u_col_lamp;
}

// 局部灯：检修平台泛光灯、上层平台顶灯、升降舱舱内灯
vec3 localLights(vec3 q, vec3 n, vec3 v, vec3 diffCol, vec3 F0, float a, vec3 T, float aniso) {
    vec3 sum = vec3(0.0);
    // 检修平台泛光灯（聚光，朝平台中部向下）
    vec3 fpos = vec3(GX - 12.6, 5.1, -40.0);
    vec3 L = fpos - q;
    float d2 = dot(L, L);
    if (d2 < 1600.0) {
        vec3 l = L * inversesqrt(d2);
        vec3 sdir = normalize(vec3(0.62, -0.55, -0.56));
        float cone = smoothstep(0.55, 0.85, dot(-l, sdir));
        float att = u_light.z * 520.0 * cone / (d2 + 1.0) * (1.0 - smoothstep(900.0, 1600.0, d2));
        sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
    }
    // 上层平台顶灯
    vec3 upos = vec3(GX + 4.0, 31.0, 44.0);
    L = upos - q;
    d2 = dot(L, L);
    if (d2 < 2500.0) {
        vec3 l = L * inversesqrt(d2);
        float att = u_light.z * 260.0 / (d2 + 2.0) * (1.0 - smoothstep(1200.0, 2500.0, d2));
        sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
    }
    // 升降舱舱内灯
    vec3 cpos = vec3(TWR.x, u_mech.z + 0.4, TWR.y);
    L = cpos - q;
    d2 = dot(L, L);
    if (d2 < 400.0) {
        vec3 l = L * inversesqrt(d2);
        float att = u_light.z * 40.0 / (d2 + 1.0) * (1.0 - smoothstep(150.0, 400.0, d2));
        sum += evalLight(n, v, l, diffCol, F0, a, T, aniso) * att;
    }
    return sum * u_col_lamp;
}

// 沿视线累积体积光：锻炉（含叶片光柱）、青色光带的光晕、泛光灯光锥
vec3 volumetric(vec3 ro, vec3 rd, float tEnd, float dither) {
    float tMax = min(tEnd, 300.0);
    float sig = u_fogp.x;
    vec3 acc = vec3(0.0);
    float nv = u_quality.x;
    for (int i = 0; i < 40; i++) {
        if (float(i) >= nv) {
            break;
        }
        float fi = (float(i) + dither) / nv;
        float t = tMax * fi * fi;
        float dt = tMax * 2.0 * fi / nv + 0.02;
        vec3 x = ro + rd * t;
        vec3 q = cellLocal(x);
        vec3 L = furnLightPos(q) - q;
        float d2 = dot(L, L);
        vec3 l = L * inversesqrt(d2);
        float ph = phaseHG(dot(l, rd), 0.38) * 4.0 * PI;
        float occF = furnaceVolOcc(q);
        vec3 lf = u_col_furn * (u_light.x * ph * occF / (d2 + 80.0));
        // 炉口上方的光柱：叶片缝隙间透出的熔芯光，衰减比点光慢，随叶片旋转
        vec3 fp = q - vec3(0.0, u_furn.x, 0.0);
        float rho = length(fp.xz);
        if (fp.y > 0.0 && rho < 17.0 && fp.y < 400.0) {
            float colm = (1.0 - smoothstep(10.0, 16.5, rho)) * (0.25 + 0.75 * exp(-fp.y / 40.0)) * exp(-fp.y / 260.0) * occF;
            lf += u_col_furn * (u_emit.x * 5.5 * colm);
        }
        float r = length(q.xz);
        float lvq = round((q.y + 0.66) / LVL);
        float ly = q.y + 0.66 - LVL * lvq;
        float dr = length(vec2(r - 56.45, ly));
        float lvOn = (hash11(mod(lvq, 25.0) + 3.1) > 0.55) ? 1.0 : 0.05;
        vec3 lc = u_col_slot * (u_light.y * 0.02 * lvOn / (dr * dr + 0.8));
        vec3 fl = vec3(GX - 12.6, 5.1, -40.0) - q;
        float fd2 = dot(fl, fl);
        float cone = smoothstep(0.6, 0.9, dot(-fl * inversesqrt(fd2), normalize(vec3(0.62, -0.55, -0.56))));
        vec3 ll = u_col_lamp * (u_light.z * 14.0 * cone / (fd2 + 2.0));
        acc += exp(-sig * t) * sig * dt * (lf + lc + ll);
    }
    return acc * u_emit.w;
}

// 射线在连廊隧道里的长度占比（xz 平面上与隧道包围盒求交，含相邻格子的那一段）
float tunnelFraction(vec3 ro, vec3 rd, float t) {
    vec3 qc = cellLocal(ro);
    vec2 o = qc.xz;
    vec2 d = rd.xz;
    vec2 inv = vec2(1.0 / ((abs(d.x) > 1e-5) ? d.x : 1e-5), 1.0 / ((abs(d.y) > 1e-5) ? d.y : 1e-5));
    float inside = 0.0;
    for (int k = 0; k < 2; k++) {
        vec2 bmin = vec2(GX - GHW, 52.0 - CELL * float(k));
        vec2 bmax = vec2(GX + GHW, 188.0 - CELL * float(k));
        vec2 t0 = (bmin - o) * inv;
        vec2 t1 = (bmax - o) * inv;
        vec2 tn = min(t0, t1);
        vec2 tf = max(t0, t1);
        float a = max(max(tn.x, tn.y), 0.0);
        float b = min(min(tf.x, tf.y), t);
        inside += max(b - a, 0.0);
    }
    return clamp(inside / max(t, 1e-3), 0.0, 1.0);
}

// 近处暗橙、远处深蓝；向下看的远处更暗（深渊），向上略亮
vec3 fogColorAt(float t, vec3 rd) {
    vec3 far = u_fog_far * mix(1.0, 0.55, smoothstep(0.0, -0.8, rd.y)) * mix(1.0, 1.35, smoothstep(0.1, 0.9, rd.y));
    return mix(u_fog_near, far, 1.0 - exp(-t / u_fogp.y));
}

void fragment() {
    vec2 ndc = v_ndc + u_proj.zw;
    vec3 ro = u_cam_pos;
    vec3 rd = normalize(u_cam_fwd + ndc.x * u_proj.x * u_cam_right + ndc.y * u_proj.y * u_cam_up);
    float pixAng = u_frame.z;
    float sig = u_fogp.x;
    float tFar = u_fogp.w;

    // ---- 光线步进 ----
    float t = 0.02;
    float id = 0.0;
    float steps = 0.0;
    bool hit = false;
    for (int i = 0; i < 220; i++) {
        if (float(i) >= u_frame.w) {
            break;
        }
        float lod = pixAng * t;
        vec2 h = mapScene(ro + rd * t, lod);
        if (h.x < max(0.0006, lod * 0.55)) {
            hit = true;
            id = h.y;
            break;
        }
        t += h.x * 0.88;
        steps += 1.0;
        if (t > tFar) {
            break;
        }
    }
    t = min(t, tFar);
    vec3 pos = ro + rd * t;
    float lod = pixAng * t;

    // 法线（四面体采样，ε 随像素覆盖增大）
    float e = max(0.0012, lod * 0.6);
    vec2 k = vec2(1.0, -1.0);
    float n1 = mapD(pos + k.xyy * e, lod);
    float n2 = mapD(pos + k.yyx * e, lod);
    float n3 = mapD(pos + k.yxy * e, lod);
    float n4 = mapD(pos + k.xxx * e, lod);
    vec3 nrm = k.xyy * n1 + k.yyx * n2 + k.yxy * n3 + k.xxx * n4;
    nrm = (dot(nrm, nrm) > 1e-12) ? normalize(nrm) : (-rd);
    // 法线在屏幕上的变化量：用于高光抗锯齿（必须在一致控制流里求导）
    vec3 dnx = dFdx(nrm);
    vec3 dny = dFdy(nrm);
    float nVar = 0.5 * (dot(dnx, dnx) + dot(dny, dny));

    float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy + vec2(5.588, 1.36) * mod(u_frame.y, 64.0), vec2(0.06711056, 0.00583715))));

    vec3 col = vec3(0.0);
    float cover = 1.0;
    bool dynamicObj = false;
    if (hit) {
        if (dot(nrm, rd) > 0.0) {
            nrm = normalize(nrm - rd * (dot(nrm, rd) + 0.01));
        }
        vec3 q = cellLocal(pos);
        // 曲率（较大 ε，判断凸边用于磨损）
        float curv = 0.0;
        if (lod < 0.06) {
            // 近处才算：远处磨损边缘本来就小于一个像素
            float e2 = max(0.035, lod * 2.0);
            float c1 = mapD(pos + k.xyy * e2, lod);
            float c2 = mapD(pos + k.yyx * e2, lod);
            float c3 = mapD(pos + k.yxy * e2, lod);
            float c4 = mapD(pos + k.xxx * e2, lod);
            // 减去命中点自身的残余距离（四面体法线采样的平均值），否则远处平面也会被当成凸边
            float d0 = 0.25 * (n1 + n2 + n3 + n4);
            curv = (c1 + c2 + c3 + c4 - 4.0 * d0) / (4.0 * e2);
        }
        float ao = calcAO(pos + nrm * 0.004, nrm, lod);
        // 步进次数加深缝隙与平台底部
        ao *= 1.0 - 0.38 * smoothstep(28.0, 150.0, steps);

        vec3 albedo;
        float rough;
        float metal;
        vec3 emis;
        vec3 tanT;
        float aniso;
        surfaceMaterial(id, pos, q, nrm, lod, curv, ao, albedo, rough, metal, emis, tanT, aniso, cover);
        // 高光抗锯齿：按法线变化放宽粗糙度
        float a = rough * rough;
        a = sqrt(a * a + min(2.0 * nVar, 0.2));
        a = max(a, 0.004);
        vec3 v = -rd;
        vec3 F0 = mix(vec3(0.04), albedo, metal);
        vec3 diffCol = albedo * (1.0 - metal);

        // 锻炉主光：熔芯 → 表面，SDF 软阴影
        vec3 lpos = furnLightPos(q);
        vec3 L = lpos - q;
        float d2 = dot(L, L);
        float dist = sqrt(d2);
        vec3 l = L / dist;
        float att = u_light.x / (d2 + 60.0);
        if (dot(nrm, l) > 0.0 && att > 0.0004) {
            float sh = softShadow(pos + nrm * 0.03, l, dist - 1.5, pixAng);
            col += evalLight(nrm, v, l, diffCol, F0, a, tanT, aniso) * u_col_furn * (att * sh);
        }
        col += slotLights(q, nrm, v, diffCol, F0, a, tanT, aniso) * ao;
        col += localLights(q, nrm, v, diffCol, F0, a, tanT, aniso) * mix(1.0, ao, 0.6);
        col += practicalLights(q, nrm, v, diffCol, F0, a, tanT, aniso) * mix(1.0, ao, 0.5);

        // 环境：上方冷光、下方与锻炉附近的暖反弹
        vec3 fcen = vec3(0.0, u_furn.x, 0.0);
        float fd = length(q - fcen);
        vec3 warm = u_fog_near * 0.8 + u_col_furn * (u_light.x * 0.00016 / (1.0 + fd * fd * 0.0016));
        vec3 cold = u_fog_far * 9.0 + vec3(0.008);
        vec3 amb = mix(warm, cold, nrm.y * 0.5 + 0.5) * u_light.w;
        col += diffCol * amb * ao;
        vec3 R = reflect(rd, nrm);
        if (aniso > 0.02) {
            vec3 B = normalize(cross(nrm, tanT));
            vec3 bentN = normalize(mix(nrm, cross(B, v), aniso * 0.35));
            R = reflect(rd, bentN);
        }
        float NoV = max(dot(nrm, v), 0.0);
        vec3 Fr = F0 + (max(vec3(1.0 - rough), F0) - F0) * pow(1.0 - NoV, 5.0);
        col += envRadiance(q, R, rough) * Fr * ao * (u_light.w * 0.9 + 0.1);
        col += emis;

        dynamicObj = (length(furnaceFrame(q).xz) < 29.0 && abs(q.y - u_furn.x) < 9.0)
            || (abs(q.z - BZ) < 4.0 && q.y > BY + 0.3 && q.y < BY + 4.5)
            || (abs(q.x - TWR.x) < 2.6 && abs(q.z - TWR.y) < 2.6 && abs(q.y - u_mech.z) < 3.2);
    }

    // ---- 雾与体积光 ----
    if (u_debug.x > 0.5) {
        sig = 0.0;
    }
    float T = exp(-sig * t);
    vec3 fogc = fogColorAt(t, rd);
    if (!hit) {
        // 没有命中：远处的深蓝，朝下更暖（深处的锻炉群）
        fogc = mix(u_fog_far, u_fog_near * 1.3, smoothstep(0.2, -0.9, rd.y));
        T = 0.0;
    }
    // 隧道里的空气没有炉光照亮：按射线在隧道内的占比压暗散射色，让通往下一座井的洞口更亮
    fogc *= mix(1.0, 0.28, tunnelFraction(ro, rd, t));
    col = col * T + fogc * (1.0 - T);
    // 细杆覆盖率：不到一个像素的钢索 / 栏杆按覆盖率混向背景
    col = mix(fogc * 0.9, col, cover);
    if (u_debug.x < 0.5) {
        col += volumetric(ro, rd, hit ? t : tFar, dither);
    }
    if (u_debug.y > 0.5) {
        if (u_debug.y < 1.5) {
            col = nrm * 0.5 + 0.5;
        } else if (u_debug.y < 2.5) {
            col = vec3(fract(id * 0.37), fract(id * 0.61), fract(id * 0.13)) * (hit ? 1.0 : 0.0);
        } else if (u_debug.y < 3.5) {
            col = vec3(steps / u_frame.w);
        }
        col = col * col * 2.0;
    }

    col = max(col, vec3(0.0));
    ALBEDO = col;
    float depthOut = hit ? t : 9000.0;
    ALPHA = dynamicObj ? (-depthOut) : depthOut;
}
