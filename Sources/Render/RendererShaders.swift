// Core renderer shaders (MSL source, compiled at runtime together with ShaderCommon.header).
enum RendererShaders {
    static let source = #"""
// ============================================================ PBR mesh
struct MeshVOut {
    float4 position [[position]];
    float3 rel;
    float3 normal;
    float2 uv;
    float4 color [[flat]];
    float4 material [[flat]];
};

vertex MeshVOut meshVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device MeshVertex *verts [[buffer(0)]],
                           const device MeshInstance *inst [[buffer(1)]],
                           constant FrameUniforms &f [[buffer(2)]]) {
    MeshVertex v = verts[vid];
    MeshInstance I = inst[iid];
    float4 wp = I.model * float4(float3(v.position), 1.0);
    MeshVOut o;
    o.position = f.viewProj * wp;
    o.rel = wp.xyz;
    float3x3 nm = float3x3(I.model[0].xyz, I.model[1].xyz, I.model[2].xyz);
    o.normal = nm * float3(v.normal);
    o.uv = v.uv; o.color = I.color; o.material = I.material;
    return o;
}

inline float3 groundPattern(constant FrameUniforms &f, float3 rel, float3 base) {
    float2 w = rel.xz + f.cameraWorld.xz;
    float2 g1 = abs(fract(w / 10.0 + 0.5) - 0.5) * 10.0;     // 10 m grid
    float2 g2 = abs(fract(w / 100.0 + 0.5) - 0.5) * 100.0;   // 100 m grid
    float px = length(rel) * 0.0015 + 0.02;
    float l1 = 1.0 - smoothstep(0.0, px * 2.0 + 0.03, min(g1.x, g1.y));
    float l2 = 1.0 - smoothstep(0.0, px * 3.0 + 0.08, min(g2.x, g2.y));
    float n = fract(sin(dot(floor(w / 2.0), float2(12.9898, 78.233))) * 43758.5453);
    float3 c = base * (0.9 + 0.2 * n);
    c = mix(c, c * 0.55, l1 * 0.6);
    c = mix(c, c * 0.35, l2 * 0.8);
    return c;
}

fragment float4 meshFragment(MeshVOut in [[stage_in]], bool front [[front_facing]],
                             constant FrameUniforms &f [[buffer(2)]],
                             depth2d_array<float> shadowMap [[texture(0)]],
                             texture2d<float> skyLUT [[texture(1)]]) {
    float3 N = normalize(in.normal);
    float3 albedo = in.color.rgb;
    if (in.material.z > 0.5 && in.material.z < 1.5) albedo = groundPattern(f, in.rel, albedo);
    float3 c = shadeSurface(f, skyLUT, shadowMap, in.rel, N, albedo, in.color.a, in.material.x, 1.0);
    c += in.color.rgb * in.material.y;                         // emissive
    c = applyAerial(f, c, in.rel);
    return float4(c, 1.0);
}

// ============================================================ shadow depth
struct ShadowVOut { float4 position [[position]]; };
vertex ShadowVOut shadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device MeshVertex *verts [[buffer(0)]],
                               const device MeshInstance *inst [[buffer(1)]],
                               constant FrameUniforms &f [[buffer(2)]],
                               constant uint &cascade [[buffer(3)]]) {
    float4 wp = inst[iid].model * float4(float3(verts[vid].position), 1.0);
    ShadowVOut o; o.position = f.cascadeViewProj[cascade] * wp;
    o.position.z = max(o.position.z, 0.0);                    // pancaking: casters behind near plane
    return o;
}

// ============================================================ sky-view LUT (compute)
kernel void skyViewLUT(texture2d<float, access::write> out [[texture(0)]],
                       constant FrameUniforms &f [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    float3 rd = skyLUTDir(uv);
    float3 ro = planetPos(f, float3(0.0));
    float tG = raySphereNear(ro, rd, Rg);
    float tT = raySphereFar(ro, rd, Rt);
    float tMax = tG > 0.0 ? tG : tT;
    float3 T;
    float3 L = tMax > 0.0 ? integrateScattering(ro, rd, tMax, f.sunDir.xyz, 32, T) : float3(0.0);
    if (tG > 0.0) {                                           // lit ground albedo seen through the atmosphere
        float3 p = ro + rd * tG;
        float3 n = normalize(p);
        L += T * transmittanceToSun(p, f.sunDir.xyz) * saturate(dot(n, f.sunDir.xyz)) * 0.12 / PI;
    }
    out.write(float4(L, 1.0), gid);
}

// ============================================================ sky (fullscreen)
struct FSOut { float4 position [[position]]; float2 uv; };
vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
}
fragment float4 skyFragment(FSOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]],
                            texture2d<float> skyLUT [[texture(1)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float4 h = f.invViewProj * float4(ndc, 1.0, 1.0);
    float3 rd = normalize(h.xyz / h.w);
    float3 c = sampleSky(skyLUT, rd) * f.sunColor.rgb * f.sunDir.w;
    // Sun disk with limb darkening, attenuated by atmospheric transmittance.
    float cosA = dot(rd, f.sunDir.xyz), r = f.sunColor.w;
    float d = acos(clamp(cosA, -1.0, 1.0)) / r;
    if (d < 1.0) {
        float mu = sqrt(max(0.0, 1.0 - d * d));
        float3 limb = pow(float3(mu), float3(0.397, 0.503, 0.652));
        float3 T = transmittanceToSun(planetPos(f, float3(0.0)), rd);
        float tG = raySphereNear(planetPos(f, float3(0.0)), rd, Rg);
        if (tG < 0.0) c += f.sunColor.rgb * f.sunDir.w * T * limb * 4000.0 * smoothstep(1.0, 0.9, d);
    }
    return float4(c, 1.0);
}

// ============================================================ debug lines
struct LineVertex { packed_float3 position; packed_float4 color; };
struct LineVOut { float4 position [[position]]; float4 color; };
vertex LineVOut lineVertex(uint vid [[vertex_id]], const device LineVertex *v [[buffer(0)]],
                           constant FrameUniforms &f [[buffer(2)]]) {
    LineVOut o; o.position = f.viewProj * float4(float3(v[vid].position), 1.0); o.color = float4(v[vid].color); return o;
}
fragment float4 lineFragment(LineVOut in [[stage_in]]) { return in.color; }

// ============================================================ bloom (physically-based mip chain)
kernel void bloomDownsample(texture2d<float> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant uint &firstPass [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 ts = 1.0 / float2(src.get_width(), src.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float3 a = src.sample(s, uv + ts * float2(-2, -2)).rgb, b = src.sample(s, uv + ts * float2(0, -2)).rgb, c = src.sample(s, uv + ts * float2(2, -2)).rgb;
    float3 d = src.sample(s, uv + ts * float2(-2, 0)).rgb, e = src.sample(s, uv).rgb, ff = src.sample(s, uv + ts * float2(2, 0)).rgb;
    float3 g = src.sample(s, uv + ts * float2(-2, 2)).rgb, h = src.sample(s, uv + ts * float2(0, 2)).rgb, i = src.sample(s, uv + ts * float2(2, 2)).rgb;
    float3 j = src.sample(s, uv + ts * float2(-1, -1)).rgb, k = src.sample(s, uv + ts * float2(1, -1)).rgb;
    float3 l = src.sample(s, uv + ts * float2(-1, 1)).rgb, m = src.sample(s, uv + ts * float2(1, 1)).rgb;
    float3 r = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + ff + h) * 0.0625 + (j + k + l + m) * 0.125;
    if (firstPass != 0) r = min(r, float3(6.0e4));            // guard against inf/NaN fireflies
    r = max(r, 0.0);
    dst.write(float4(r, 1.0), gid);
}
kernel void bloomUpsample(texture2d<float> lower [[texture(0)]],
                          texture2d<float, access::read_write> dst [[texture(1)]],
                          constant float &radius [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 t = radius / float2(lower.get_width(), lower.get_height());
    float3 sum = lower.sample(s, uv).rgb * 4.0;
    sum += (lower.sample(s, uv + float2(-t.x, 0)).rgb + lower.sample(s, uv + float2(t.x, 0)).rgb +
            lower.sample(s, uv + float2(0, -t.y)).rgb + lower.sample(s, uv + float2(0, t.y)).rgb) * 2.0;
    sum += lower.sample(s, uv + float2(-t.x, -t.y)).rgb + lower.sample(s, uv + float2(t.x, -t.y)).rgb +
           lower.sample(s, uv + float2(-t.x, t.y)).rgb + lower.sample(s, uv + float2(t.x, t.y)).rgb;
    float3 cur = dst.read(gid).rgb;
    dst.write(float4(cur + sum / 16.0, 1.0), gid);
}

// ============================================================ TAA resolve
inline float3 rgb2ycocg(float3 c) { return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25))); }
inline float3 ycocg2rgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }
inline float3 tmap(float3 c) { return c / (1.0 + max(c.r, max(c.g, c.b))); }
inline float3 tunmap(float3 c) { return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4); }

kernel void taaResolve(texture2d<float> current [[texture(0)]],
                       texture2d<float> history [[texture(1)]],
                       depth2d<float> depth [[texture(2)]],
                       texture2d<float, access::write> out [[texture(3)]],
                       constant FrameUniforms &f [[buffer(2)]],
                       constant uint &resetHistory [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    float3 m1 = 0.0, m2 = 0.0; float3 cur = 0.0;
    float closest = 0.0; int2 cOff = int2(0);
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        uint2 p = uint2(clamp(int2(gid) + int2(x, y), int2(0), int2(w - 1, h - 1)));
        float3 c = rgb2ycocg(tmap(current.read(p).rgb));
        m1 += c; m2 += c * c;
        if (x == 0 && y == 0) cur = c;
        float d = depth.read(p);
        if (d > closest) { closest = d; cOff = int2(x, y); }    // reverse-Z: larger = closer
    }
    float3 mean = m1 / 9.0, sd = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 uvC = (float2(int2(gid) + cOff) + 0.5) / float2(w, h);
    float2 ndc = float2(uvC.x * 2.0 - 1.0, 1.0 - uvC.y * 2.0);
    float4 rel = f.invViewProj * float4(ndc, max(closest, 1e-7), 1.0);
    rel /= rel.w;
    float4 prev = f.prevViewProj * float4(rel.xyz, 1.0);
    float2 prevUV = float2(prev.x / prev.w * 0.5 + 0.5, 0.5 - prev.y / prev.w * 0.5);
    float2 velocity = prevUV - uvC;
    float2 hUV = uv + velocity;
    float3 result;
    if (resetHistory != 0 || any(hUV < 0.0) || any(hUV > 1.0)) {
        result = ycocg2rgb(cur);
    } else {
        float3 hist = rgb2ycocg(tmap(history.sample(ls, hUV).rgb));
        float3 lo = mean - sd * 1.25, hi = mean + sd * 1.25;
        hist = clamp(hist, lo, hi);
        float speed = length(velocity * float2(w, h));
        float alpha = mix(0.08, 0.25, saturate(speed / 8.0));
        result = ycocg2rgb(mix(hist, cur, alpha));
    }
    out.write(float4(tunmap(max(result, 0.0)), 1.0), gid);
}

// ============================================================ tonemap (ACES fitted, Hill) + bloom composite
constant float3x3 ACESIn = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
constant float3x3 ACESOut = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
inline float3 RRTAndODTFit(float3 v) { float3 a = v * (v + 0.0245786) - 0.000090537; float3 b = v * (0.983729 * v + 0.4329510) + 0.238081; return a / b; }
inline float3 acesFitted(float3 c) { c = ACESIn * c; c = RRTAndODTFit(c); c = ACESOut * c; return saturate(c); }

fragment float4 tonemapFragment(FSOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]],
                                texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = hdr.sample(s, in.uv).rgb;
    float3 b = bloom.sample(s, in.uv).rgb;
    c = mix(c, b, f.atmos.w);
    c *= f.params.y;
    c = acesFitted(c);
    // Triangular dither to kill banding in the sky gradient.
    float n = fract(sin(dot(in.position.xy + f.params.x, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    c += n / 255.0;
    return float4(c, 1.0);
}
"""#
}
