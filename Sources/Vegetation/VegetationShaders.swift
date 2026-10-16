// OWNED BY vegetation builder. ---------------------------------------------------------------
// MSL for trees (GPU culling + LOD selection into indirect draws, bark/leaf shading with wind),
// octahedral impostors (bake + draw), GPU grass (compute generation, wind gusts, interaction texture).
// Compiled at runtime via ShaderLibrary (ShaderCommon.header is prepended).
enum VegetationShaders {
    static let impostorFrames = 8
    static let source = #"""
// ============================================================ shared vegetation types
struct TreeInst { float4 posScale; float4 quat; uint tmpl; uint flags; float tint; float phase; };
struct TreeTemplateGPU { float4 barkColor; float4 leafColor; float4 dims; uint4 lod0; uint4 lod1; uint4 region; };
// dims: x bounding radius (unit scale), y height, z trunk radius, w species
struct VegCull { float4 planes[6]; float4 camPos; float4 lodDist; uint4 counts; float4x4 casc[3]; };
// args per template: 5 indexed-indirect entries x5 uints (lod0, lod1, shadow c0, c1, c2); impostor block at T*25.
// visible regions (stride N): 0 lod0, 1 lod1, 2..4 shadow cascade 0..2, 5 impostor
// lodDist: x LOD0 max (per unit scale), y LOD1 max, z impostor max, w shadow caster distance
// counts: x tree count, y template count, z total N (region stride), w unused
constant int IMP_F = 8;

inline float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
inline float4 qconj(float4 q) { return float4(-q.xyz, q.w); }
inline float vegHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
inline float vegNoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(vegHash(i), vegHash(i + float2(1, 0)), f.x), mix(vegHash(i + float2(0, 1)), vegHash(i + float2(1, 1)), f.x), f.y);
}

// Procedural silhouettes inside leaf cards. kind: 0 broadleaf cluster, 1 needles, 2 palm frond, 3 birch.
inline float leafMask(float2 uv, int kind) {
    float u = uv.x, v = uv.y;
    if (kind == 1) {
        float w = 0.12 + v * 0.88;
        float a = (u - 0.5) / w;
        if (abs(a) > 0.5 || v > 0.97) return 0.0;
        float stripe = abs(fract(a * 7.0 + 0.5) - 0.5);
        return stripe < 0.2 ? 1.0 : 0.0;
    }
    if (kind == 2) {
        float x = abs(u - 0.5) * 2.0;
        if (x < 0.05) return 1.0;
        float env = 0.95 * sin(clamp(v, 0.0, 1.0) * 3.14159);
        return (x < env && fract(v * 18.0 - x * 2.2) < 0.55) ? 1.0 : 0.0;
    }
    int n = kind == 3 ? 5 : 3;
    float r = kind == 3 ? 0.15 : 0.0;
    for (int i = 0; i < n; i++) {
        float fi = float(i);
        float2 c = kind == 3 ? float2(0.5 + 0.28 * sin(fi * 2.4), 0.18 + fi * 0.16)
                             : float2(0.5 + 0.2 * sin(fi * 2.1 + 0.5), 0.22 + fi * 0.27);
        float2 d = float2(u, v) - c;
        if (kind == 3) { if (dot(d, d) < r * r) return 1.0; }
        else {
            float ang = fi * 1.3 - 0.6; float cs = cos(ang), sn = sin(ang);
            float2 q = float2(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
            if ((q.x * q.x) / (0.2 * 0.2) + (q.y * q.y) / (0.14 * 0.14) < 1.0) return 1.0;
        }
    }
    return 0.0;
}

struct VegMat { float3 albedo; float roughness; float alpha; bool leaf; };
inline VegMat vegMaterial(float2 uv, TreeTemplateGPU T, float tint) {
    VegMat m;
    m.leaf = uv.y < -0.5;
    if (m.leaf) {
        int kind = int(floor((-uv.y - 1.0) * 0.5 + 0.001));
        float2 luv = float2(uv.x, -uv.y - 1.0 - float(kind) * 2.0);
        m.alpha = leafMask(luv, kind);
        float var = 0.8 + 0.4 * vegHash(floor(luv * 3.0) + tint * 17.0);
        m.albedo = T.leafColor.rgb * var * (0.85 + 0.3 * tint) * (0.85 + 0.3 * luv.y);
        m.roughness = 0.6;
    } else {
        m.alpha = 1.0;
        float n = vegNoise(float2(uv.x * 10.0, uv.y * 1.5)) * 0.6 + vegNoise(float2(uv.x * 30.0, uv.y * 6.0)) * 0.4;
        float3 c = T.barkColor.rgb;
        if (int(T.dims.w) == 2) {           // birch: white bark with dark lenticels
            float mark = step(0.78, vegHash(float2(floor(uv.x * 5.0), floor(uv.y * 7.0)))) * step(0.5, fract(uv.y * 7.0));
            c = mix(c * (0.9 + 0.2 * n), float3(0.03, 0.03, 0.025), mark);
        } else {
            float ridge = 0.65 + 0.35 * abs(sin(uv.x * 6.2831 * 6.0 + n * 4.0));
            c *= ridge * (0.8 + 0.4 * n);
        }
        m.albedo = c;
        m.roughness = T.barkColor.w;
    }
    return m;
}

inline float3 treeWind(constant FrameUniforms &f, float3 root, float3 lp, float height, float phase, bool leaf) {
    float3 w = f.wind.xyz; float ws = length(w);
    float h = saturate(lp.y / max(height, 1.0));
    float t = f.params.x;
    float gust = 0.7 + 0.3 * sin(dot(root.xz, float2(0.021, 0.017)) - t * (0.5 + ws * 0.06)) + 0.15 * sin(t * 1.7 + phase);
    float3 dir = ws > 1e-3 ? w / ws : float3(0.0);
    float3 off = dir * (ws * ws * 0.004 + ws * 0.01) * gust * h * h * (height / 15.0);
    off += float3(sin(t * 1.1 + phase), 0.0, cos(t * 0.9 + phase * 1.3)) * 0.02 * h * h * (ws + 0.5);
    if (leaf) off += sin(t * (6.0 + ws * 0.3) + dot(lp, float3(3.1, 2.3, 1.7))) * float3(0.4, 0.6, 0.4) * 0.012 * (ws + 0.6);
    return off;
}


// Lean PBR for vegetation: same model as shadeSurface but with the sun transmittance (sunE) supplied
// per vertex/instance instead of an 8-step march per pixel; also returns the shadow term.
inline float3 vegShade(constant FrameUniforms &f, texture2d<float> skyLUT, depth2d_array<float> shadowMap,
                       float3 rel, float3 N, float3 albedo, float roughness, float ao, float3 sunE, thread float &shadow) {
    float3 V = normalize(-rel);
    float3 Ls = f.sunDir.xyz;
    float NoV = max(dot(N, V), 1e-4), NoL = saturate(dot(N, Ls));
    float a = max(roughness * roughness, 0.002);
    float viewDepth = dot(rel, f.cameraForward.xyz);
    shadow = sampleShadow(f, shadowMap, rel, N, viewDepth);
    float3 H = normalize(V + Ls);
    float3 F = F_Schlick(float3(0.04), saturate(dot(V, H)));
    float3 spec = D_GGX(saturate(dot(N, H)), a) * V_SmithGGXCorrelated(NoV, NoL, a) * F;
    float3 direct = (albedo * (1.0 - F) / PI + spec) * sunE * NoL * shadow;
    float3 skyScale = f.sunColor.rgb * f.sunDir.w;
    float3 nUp = normalize(N + float3(0, 0.6, 0));
    float3 irradiance = sampleSky(skyLUT, nUp) * skyScale * PI * 0.5 * saturate(0.5 + 0.5 * N.y);
    float2 ab = envBRDFApprox(roughness, NoV);
    float3 ambient = (albedo * irradiance / PI + sampleSky(skyLUT, nUp) * skyScale * (0.04 * ab.x + ab.y)) * ao;
    return direct + ambient;
}
inline float3 sunIlluminance(constant FrameUniforms &f, float3 rel) {
    return f.sunColor.rgb * f.sunDir.w * transmittanceToSun(planetPos(f, rel), f.sunDir.xyz);
}

// ============================================================ tree culling + LOD (compute)
kernel void treeCull(device const TreeInst *trees [[buffer(0)]],
                     device const TreeTemplateGPU *tmpl [[buffer(1)]],
                     constant VegCull &cu [[buffer(2)]],
                     device atomic_uint *args [[buffer(3)]],
                     device uint *visible [[buffer(4)]],
                     uint i [[thread_position_in_grid]]) {
    if (i >= cu.counts.x) return;
    TreeInst t = trees[i];
    if ((t.flags & 1u) != 0u) return;
    TreeTemplateGPU T = tmpl[t.tmpl];
    float s = t.posScale.w;
    float3 c = t.posScale.xyz - cu.camPos.xyz + float3(0.0, T.dims.y * 0.5 * s, 0.0);
    float r = T.dims.x * s;
    float d = length(c);
    uint N = cu.counts.z, base = T.region.x, a5 = t.tmpl * 25u;
    if (d < cu.lodDist.w) {
        // Per-cascade caster culling: test the bounding sphere against each cascade's ortho xy extent
        // (depth is not culled: casters between the sun and the cascade must still be drawn).
        for (uint k = 0u; k < 3u; k++) {
            float4x4 m = cu.casc[k];
            float4 q = m * float4(c, 1.0);
            float sx = length(float3(m[0].x, m[1].x, m[2].x)), sy = length(float3(m[0].y, m[1].y, m[2].y));
            if (fabs(q.x) > 1.0 + r * sx || fabs(q.y) > 1.0 + r * sy) continue;
            uint slot = atomic_fetch_add_explicit(&args[a5 + 11u + 5u * k], 1u, memory_order_relaxed);
            visible[(2u + k) * N + base + slot] = i;
        }
    }
    for (int p = 0; p < 6; p++) if (dot(cu.planes[p].xyz, c) + cu.planes[p].w < -r) return;
    float ds = d / max(s, 0.3);
    if (ds < cu.lodDist.x) {
        uint slot = atomic_fetch_add_explicit(&args[a5 + 1u], 1u, memory_order_relaxed);
        visible[base + slot] = i;
    } else if (ds < cu.lodDist.y) {
        uint slot = atomic_fetch_add_explicit(&args[a5 + 6u], 1u, memory_order_relaxed);
        visible[N + base + slot] = i;
    } else if (d < cu.lodDist.z) {
        uint slot = atomic_fetch_add_explicit(&args[cu.counts.y * 25u + t.tmpl * 4u + 1u], 1u, memory_order_relaxed);
        visible[5u * N + base + slot] = i;
    }
}

// ============================================================ tree mesh draw
struct TreeVOut {
    float4 position [[position]];
    float3 rel;
    float3 normal;
    float2 uv;
    float3 aerL;
    float3 aerT;
    float3 sunE [[flat]];
    uint tmpl [[flat]];
    float tint [[flat]];
};

vertex TreeVOut treeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device MeshVertex *verts [[buffer(0)]],
                           const device uint *visible [[buffer(1)]],
                           constant FrameUniforms &f [[buffer(2)]],
                           const device TreeInst *trees [[buffer(4)]],
                           const device TreeTemplateGPU *tmpl [[buffer(5)]],
                           constant VegCull &cu [[buffer(6)]]) {
    TreeInst t = trees[visible[iid]];
    MeshVertex v = verts[vid];
    float s = t.posScale.w;
    float3 lp = float3(v.position) * s;
    bool leaf = v.uv.y < -0.5;
    float3 rel = t.posScale.xyz - cu.camPos.xyz + qrot(t.quat, lp);
    if ((t.flags & 2u) == 0u) rel += treeWind(f, t.posScale.xyz, lp, tmpl[t.tmpl].dims.y * s, t.phase, leaf);
    TreeVOut o;
    o.position = f.viewProj * float4(rel, 1.0);
    o.rel = rel;
    o.normal = qrot(t.quat, float3(v.normal));
    o.uv = v.uv; o.tmpl = t.tmpl; o.tint = t.tint;
    float3 T; o.aerL = aerialPerspective(f, rel, T); o.aerT = T;      // per-vertex aerial perspective
    o.sunE = sunIlluminance(f, t.posScale.xyz - cu.camPos.xyz);
    return o;
}

fragment float4 treeFragment(TreeVOut in [[stage_in]], bool front [[front_facing]],
                             constant FrameUniforms &f [[buffer(2)]],
                             const device TreeTemplateGPU *tmpl [[buffer(5)]],
                             depth2d_array<float> shadowMap [[texture(0)]],
                             texture2d<float> skyLUT [[texture(1)]]) {
    TreeTemplateGPU T = tmpl[in.tmpl];
    VegMat m = vegMaterial(in.uv, T, in.tint);
    if (m.alpha < 0.5) discard_fragment();
    float3 N = normalize(in.normal);
    if (m.leaf) {               // two-sided cards with bent normals: face the viewer to avoid grazing-angle specular spikes
        if (!front) N = -N;
        if (dot(N, -in.rel) < 0.0) N = normalize(N - 2.0 * dot(N, normalize(-in.rel)) * normalize(-in.rel) * 0.5);
        m.roughness = 0.75;
    }
    float ao = m.leaf ? 0.75 : 0.9;
    float sh;
    float3 c = vegShade(f, skyLUT, shadowMap, in.rel, N, m.albedo, m.roughness, ao, in.sunE, sh);
    if (m.leaf) {   // back-lit translucency through thin leaves
        float3 L = f.sunDir.xyz;
        float3 V = normalize(-in.rel);
        float back = saturate(dot(-N, L)) * 0.5 + pow(saturate(dot(-V, L)), 6.0) * 0.5;
        if (dot(N, L) < 0.0) {   // shadow term above was evaluated with the front normal; re-use with offset flipped
            float viewDepth = dot(in.rel, f.cameraForward.xyz);
            sh = sampleShadow(f, shadowMap, in.rel, -N, viewDepth);
        }
        c += m.albedo * float3(0.8, 1.0, 0.35) * in.sunE * back * sh * 0.07;
    }
    c = c * in.aerT + in.aerL;
    return float4(c, 1.0);
}

// Shadow casters (alpha-tested leaves).
struct TreeShadowOut { float4 position [[position]]; float2 uv; };
vertex TreeShadowOut treeShadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device MeshVertex *verts [[buffer(0)]],
                                      const device uint *visible [[buffer(1)]],
                                      constant FrameUniforms &f [[buffer(2)]],
                                      constant uint &cascade [[buffer(3)]],
                                      const device TreeInst *trees [[buffer(4)]],
                                      const device TreeTemplateGPU *tmpl [[buffer(5)]],
                                      constant VegCull &cu [[buffer(6)]]) {
    TreeInst t = trees[visible[iid]];
    MeshVertex v = verts[vid];
    float s = t.posScale.w;
    float3 lp = float3(v.position) * s;
    float3 rel = t.posScale.xyz - cu.camPos.xyz + qrot(t.quat, lp);
    if ((t.flags & 2u) == 0u) rel += treeWind(f, t.posScale.xyz, lp, tmpl[t.tmpl].dims.y * s, t.phase, false);
    TreeShadowOut o;
    o.position = f.cascadeViewProj[cascade] * float4(rel, 1.0);
    o.position.z = max(o.position.z, 0.0);
    o.uv = v.uv;
    return o;
}
fragment void treeShadowFragment(TreeShadowOut in [[stage_in]]) {
    if (in.uv.y < -0.5) {
        int kind = int(floor((-in.uv.y - 1.0) * 0.5 + 0.001));
        if (leafMask(float2(in.uv.x, -in.uv.y - 1.0 - float(kind) * 2.0), kind) < 0.5) discard_fragment();
    }
}

// ============================================================ octahedral impostors
inline float2 hemiOctEncode(float3 d) {
    d.y = max(d.y, 0.0);
    float3 a = abs(d); float s = a.x + a.y + a.z;
    float2 p = d.xz / max(s, 1e-6);
    return float2(p.x + p.y, p.x - p.y);
}
inline float3 hemiOctDecode(float2 e) {
    float x = (e.x + e.y) * 0.5, z = (e.x - e.y) * 0.5;
    return normalize(float3(x, 1.0 - abs(x) - abs(z), z));
}
inline void frameBasis(float3 dir, thread float3 &right, thread float3 &up) {
    float3 ref = abs(dir.y) > 0.999 ? float3(0, 0, 1) : float3(0, 1, 0);
    right = normalize(cross(ref, dir));
    up = cross(dir, right);
}

struct BakeU { float4 dir; float4 right; float4 up; float4 center; };   // center.w = radius
struct BakeOut { float4 position [[position]]; float3 normal; float2 uv; };
vertex BakeOut impostorBakeVertex(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(0)]], constant BakeU &b [[buffer(1)]]) {
    float3 p = float3(verts[vid].position) - b.center.xyz;
    float R = b.center.w;
    BakeOut o;
    o.position = float4(dot(p, b.right.xyz) / R, dot(p, b.up.xyz) / R, 0.5 - dot(p, b.dir.xyz) / (4.0 * R), 1.0);
    o.normal = float3(verts[vid].normal); o.uv = verts[vid].uv;
    return o;
}
struct BakeFrag { float4 albedo [[color(0)]]; float4 normal [[color(1)]]; };
fragment BakeFrag impostorBakeFragment(BakeOut in [[stage_in]], constant BakeU &b [[buffer(1)]], const device TreeTemplateGPU *T [[buffer(2)]]) {
    VegMat m = vegMaterial(in.uv, T[0], 0.5);
    if (m.alpha < 0.5) discard_fragment();
    float3 N = normalize(in.normal);
    if (m.leaf && dot(N, b.dir.xyz) < 0.0) N = -N;
    BakeFrag o;
    o.albedo = float4(m.albedo, 1.0);
    o.normal = float4(N * 0.5 + 0.5, m.leaf ? 1.0 : 0.0);
    return o;
}

struct ImpVOut {
    float4 position [[position]];
    float3 rel;
    float2 local;
    uint frame [[flat]];
    uint slice [[flat]];
    float4 quat [[flat]];
    float tint [[flat]];
    float3 aerL [[flat]];
    float3 aerT [[flat]];
    float3 sunE [[flat]];
};
vertex ImpVOut impostorVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device uint *visible [[buffer(1)]],
                              constant FrameUniforms &f [[buffer(2)]],
                              const device TreeInst *trees [[buffer(4)]],
                              const device TreeTemplateGPU *tmpl [[buffer(5)]],
                              constant VegCull &cu [[buffer(6)]]) {
    TreeInst t = trees[visible[iid]];
    TreeTemplateGPU T = tmpl[t.tmpl];
    float s = t.posScale.w;
    float Rl = T.dims.x;
    float3 center = t.posScale.xyz - cu.camPos.xyz + float3(0.0, T.dims.y * 0.5 * s, 0.0);
    float3 toCam = normalize(-center);
    float4 qi = qconj(t.quat);
    float3 vl = qrot(qi, toCam);
    float2 e = hemiOctEncode(vl);
    float2 g = clamp(round((e * 0.5 + 0.5) * float(IMP_F - 1)), 0.0, float(IMP_F - 1));
    float3 fd = hemiOctDecode(g / float(IMP_F - 1) * 2.0 - 1.0);
    float3 fr, fu; frameBasis(fd, fr, fu);
    // Billboard perpendicular to the view direction.
    float3 br, bu; frameBasis(toCam, br, bu);
    float2 c = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float3 offW = (br * c.x + bu * c.y) * Rl * s;
    float3 offL = qrot(qi, offW) / s;
    ImpVOut o;
    o.rel = center + offW;
    o.position = f.viewProj * float4(o.rel, 1.0);
    o.local = float2(dot(offL, fr) / (2.0 * Rl) + 0.5, 0.5 - dot(offL, fu) / (2.0 * Rl));
    o.frame = uint(g.y) * uint(IMP_F) + uint(g.x);
    o.slice = t.tmpl; o.quat = t.quat; o.tint = t.tint;
    float3 aT; o.aerL = aerialPerspective(f, center, aT); o.aerT = aT;
    o.sunE = sunIlluminance(f, center);
    return o;
}
fragment float4 impostorFragment(ImpVOut in [[stage_in]],
                                 constant FrameUniforms &f [[buffer(2)]],
                                 depth2d_array<float> shadowMap [[texture(0)]],
                                 texture2d<float> skyLUT [[texture(1)]],
                                 texture2d_array<float> albedoAtlas [[texture(2)]],
                                 texture2d_array<float> normalAtlas [[texture(3)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    if (any(in.local < 0.0) || any(in.local > 1.0)) discard_fragment();
    float2 cell = float2(in.frame % uint(IMP_F), in.frame / uint(IMP_F));
    float2 uv = (cell + clamp(in.local, 0.01, 0.99)) / float(IMP_F);
    float4 a = albedoAtlas.sample(s, uv, in.slice, bias(-0.5));
    if (a.a < 0.5) discard_fragment();
    float4 nn = normalAtlas.sample(s, uv, in.slice, bias(-0.5));
    float3 N = normalize(qrot(in.quat, nn.xyz * 2.0 - 1.0));
    float3 albedo = a.rgb / max(a.a, 1e-3) * (0.85 + 0.3 * in.tint);
    float sh;
    float3 c = vegShade(f, skyLUT, shadowMap, in.rel, N, albedo, nn.a > 0.5 ? 0.6 : 0.9, 0.8, in.sunE, sh);
    c = c * in.aerT + in.aerL;
    return float4(c, 1.0);
}

// ============================================================ grass
struct GrassBlade { float4 pos; float4 params; float4 aerL; float4 aerT; float4 sunE; float4 amb; };    // pos.xyz world (float), w height; params x angle, y width, z seed; lighting terms per blade
struct GrassU { float4 camPos; float4 grid; float4 hmap; float4 inter; float4 planes[6]; float4 params; uint4 counts; };
// grid: x,y world origin of cell (0,0), z spacing, w N cells per side
// hmap: x,y world origin, z size (m), w texels per side
// inter: x texel size (m), y N, z,w unused
// params: x max distance, y blade height, z density multiplier, w full-density distance
// counts: x capacity

inline float2 hmapSample(texture2d<float, access::read> t, float2 p, constant GrassU &g) {
    float n = g.hmap.w;
    float2 q = (p - g.hmap.xy) / g.hmap.z * n - 0.5;
    if (any(q < 0.0) || any(q > n - 1.0)) return float2(0.0, 0.0);
    float2 i = floor(q), fq = q - i;
    uint2 a = uint2(i);
    float2 v00 = t.read(a).xy, v10 = t.read(a + uint2(1, 0)).xy, v01 = t.read(a + uint2(0, 1)).xy, v11 = t.read(a + uint2(1, 1)).xy;
    return mix(mix(v00, v10, fq.x), mix(v01, v11, fq.x), fq.y);
}

kernel void grassGenerate(texture2d<float, access::read> hmap [[texture(0)]],
                          constant GrassU &g [[buffer(0)]],
                          device GrassBlade *blades [[buffer(1)]],
                          device atomic_uint *args [[buffer(2)]],
                          constant FrameUniforms &f [[buffer(3)]],
                          texture2d<float> skyLUT [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint N = uint(g.grid.w);
    if (gid.x >= N || gid.y >= N) return;
    float sp = g.grid.z;
    float2 cell = g.grid.xy + float2(gid) * sp;
    float2 ci = round(cell / sp);
    float h1 = vegHash(ci), h2 = vegHash(ci + 17.31), h3 = vegHash(ci * 1.37 + 5.1), h4 = vegHash(ci * 0.71 + 91.7), h5 = vegHash(ci + 33.3);
    float2 p = cell + (float2(h1, h2) - 0.5) * sp * 0.98;
    float d = length(p - g.camPos.xz);
    if (d > g.params.x) return;
    float keep = d < g.params.w ? 1.0 : pow(g.params.w / d, 1.7);
    if (h3 > keep) return;
    float2 hd = hmapSample(hmap, p, g);
    if (h4 > hd.y * g.params.z) return;
    float bh = g.params.y * (0.55 + 0.9 * h5) * (0.7 + 0.3 * hd.y);
    float fade = 1.0 - smoothstep(g.params.x * 0.8, g.params.x, d);
    bh *= fade;
    float3 c = float3(p.x, hd.x + bh * 0.5, p.y) - g.camPos.xyz;
    for (int k = 0; k < 6; k++) if (dot(g.planes[k].xyz, c) + g.planes[k].w < -bh) return;
    uint slot = atomic_fetch_add_explicit(&args[1], 1u, memory_order_relaxed);
    if (slot >= g.counts.x) return;
    GrassBlade b;
    b.pos = float4(p.x, hd.x, p.y, bh);
    b.params = float4(h1 * 6.2831853 + h2 * 3.0, 0.045 * min(1.0 / sqrt(keep), 5.0), h4, 0.0);
    float3 rel = float3(p.x, hd.x, p.y) - g.camPos.xyz;
    float3 T; b.aerL = float4(aerialPerspective(f, rel, T), 0.0); b.aerT = float4(T, 0.0);
    b.sunE = float4(sunIlluminance(f, rel), 0.0);
    b.amb = float4(sampleSky(skyLUT, float3(0, 1, 0)) * f.sunColor.rgb * f.sunDir.w * 0.5, 0.0);
    blades[slot] = b;
}
kernel void grassClamp(device uint *args [[buffer(0)]], constant uint &cap [[buffer(1)]]) { args[1] = min(args[1], cap); }

struct Interactor { float4 posRadius; float4 dirStrength; };   // xz dir, strength, kind (0 radial, 1 directional)
struct InterU { int4 base; int4 prevBase; float4 params; };    // base.xy current base cell, base.z N; params x texel, y dt, z recover s, w count
kernel void grassInteract(texture2d<float, access::read_write> tex [[texture(0)]],
                          constant InterU &u [[buffer(0)]],
                          const device Interactor *ints [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int N = u.base.z;
    if (int(gid.x) >= N || int(gid.y) >= N) return;
    int2 gi = int2(gid);
    int2 cell = u.base.xy + (((gi - u.base.xy) % N) + N) % N;
    int2 prev = u.prevBase.xy + (((gi - u.prevBase.xy) % N) + N) % N;
    float4 v = tex.read(gid);
    if (any(cell != prev)) v = float4(0.0);
    v *= exp(-u.params.y / max(u.params.z, 0.05));
    float2 wc = (float2(cell) + 0.5) * u.params.x;
    int n = int(u.params.w);
    for (int k = 0; k < n; k++) {
        Interactor I = ints[k];
        float2 dd = wc - I.posRadius.xz;
        float dist = length(dd);
        if (dist >= I.posRadius.w) continue;
        float s = I.dirStrength.z * (1.0 - dist / I.posRadius.w);
        float2 radial = dist > 1e-3 ? dd / dist : float2(1, 0);
        float2 dir = I.dirStrength.w > 0.5 ? normalize(mix(radial, I.dirStrength.xy, 0.7) + 1e-4) : radial;
        if (s > v.z) { v.xy = dir * s; v.z = s; }
    }
    tex.write(v, gid);
}

struct GrassVOut { float4 position [[position]]; float3 rel; float3 normal; float t; float seed [[flat]]; float3 aerL [[flat]]; float3 aerT [[flat]]; float3 sunE [[flat]]; float3 amb [[flat]]; };
vertex GrassVOut grassVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device GrassBlade *blades [[buffer(0)]],
                             constant FrameUniforms &f [[buffer(2)]],
                             constant GrassU &g [[buffer(3)]],
                             texture2d<float, access::read> inter [[texture(0)]]) {
    GrassBlade b = blades[iid];
    float t = float(vid / 2u) / 4.0;
    float side = (vid & 1u) ? 1.0 : -1.0;
    if (vid >= 8u) { t = 1.0; side = 0.0; }
    float ang = b.params.x;
    float3 facing = float3(cos(ang), 0.0, sin(ang));
    float3 sideDir = float3(-sin(ang), 0.0, cos(ang));
    float h = b.pos.w;
    float3 base = b.pos.xyz - g.camPos.xyz;
    float3 B = facing * h * (0.12 + 0.25 * b.params.z);
    // Wind: travelling gust field along the wind direction plus per-blade flutter.
    float3 w = f.wind.xyz; float ws = length(w);
    float time = f.params.x;
    if (ws > 1e-3) {
        float3 wd = w / ws;
        float along = dot(b.pos.xz, wd.xz);
        float gust = 0.55 + 0.45 * sin(along * 0.15 - time * ws * 0.15) * (0.6 + 0.4 * sin(dot(b.pos.xz, float2(-wd.z, wd.x)) * 0.07 + time * 0.3));
        float flutter = 0.12 * sin(time * (4.0 + ws * 0.4) + b.params.z * 40.0);
        B += wd * h * saturate(ws * 0.06 * gust + flutter * saturate(ws * 0.1));
    }
    // Interaction (trample / wheel / rotor wash) from the world-anchored toroidal texture.
    int N = int(g.inter.y);
    int2 cell = int2(floor(b.pos.xz / g.inter.x));
    uint2 tc = uint2(((cell % N) + N) % N);
    float4 I = inter.read(tc);
    float fl = saturate(I.z);
    if (fl > 0.01) B = mix(B, float3(I.x, 0.0, I.y) / max(length(I.xy), 1e-3) * h * 0.95, fl);
    float bl = length(B);
    if (bl > 0.95 * h) B *= 0.95 * h / bl;
    float up = sqrt(max(h * h - dot(B, B), 0.03 * h * h));
    float3 P = base + float3(0.0, up * t, 0.0) + B * (t * t);
    float3 tangent = normalize(float3(0.0, up, 0.0) + 2.0 * B * t + 1e-5);
    float width = b.params.y * (1.0 - t * 0.85);
    P += sideDir * side * width * 0.5;
    GrassVOut o;
    o.rel = P;
    o.position = f.viewProj * float4(P, 1.0);
    o.normal = normalize(cross(sideDir, tangent));
    o.t = t; o.seed = b.params.z;
    o.aerL = b.aerL.xyz; o.aerT = b.aerT.xyz; o.sunE = b.sunE.xyz; o.amb = b.amb.xyz;   // per-blade lighting (from compute)
    return o;
}
fragment float4 grassFragment(GrassVOut in [[stage_in]], bool front [[front_facing]],
                              constant FrameUniforms &f [[buffer(2)]],
                              depth2d_array<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    if (!front) N = -N;
    N = normalize(mix(N, float3(0, 1, 0), 0.45));
    float3 baseC = float3(0.025, 0.05, 0.012), tipC = mix(float3(0.10, 0.17, 0.035), float3(0.16, 0.17, 0.05), in.seed);
    float3 albedo = mix(baseC, tipC, in.t);
    float3 L = f.sunDir.xyz, V = normalize(-in.rel);
    float viewDepth = dot(in.rel, f.cameraForward.xyz);
    float sh = sampleShadow(f, shadowMap, in.rel, float3(0, 1, 0), viewDepth);
    float NoL = saturate(dot(N, L));
    float3 H = normalize(V + L);
    float spec = D_GGX(saturate(dot(N, H)), 0.3) * V_SmithGGXCorrelated(max(dot(N, V), 1e-3), NoL, 0.3) * 0.04;
    float back = pow(saturate(dot(-V, L)), 4.0) * in.t * 0.5 + saturate(dot(-N, L)) * 0.25;
    float ao = mix(0.35, 1.0, in.t);
    float3 c = (albedo / PI * NoL + spec * NoL + albedo * back) * in.sunE * sh + albedo * in.amb * ao;
    c = c * in.aerT + in.aerL;
    return float4(c, 1.0);
}
"""#
}
