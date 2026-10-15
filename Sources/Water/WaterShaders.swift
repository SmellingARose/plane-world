// OWNED BY water builder.
// Metal sources for the water module, compiled at runtime through ShaderLibrary (ShaderCommon.header is prepended,
// giving FrameUniforms, sky LUT sampling, aerial perspective, shadows and GGX helpers).
enum WaterShaders {
    // MARK: - FFT ocean compute
    static let ocean = #"""
struct OceanParams {
    uint N; uint logN; uint cascades; uint pad0;
    float4 L;
    float time; float choppy; float dt; float foamDecay;
    float foamThreshold; float foamGain; float pad1; float pad2;
};

inline float2 cmul(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
// A + iB for two Hermitian spectra: the inverse FFT puts a(x) in .x and b(x) in .y
inline float2 cpack(float2 a, float2 b) { return float2(a.x - b.y, a.y + b.x); }

// h(k,t) and the 8 derived spectra (height, Dx, Dz, ∂h/∂x, ∂h/∂z, ∂Dx/∂x, ∂Dz/∂z, ∂Dx/∂z) packed into 4 complex fields.
kernel void oceanSpectrum(device const float4 *h0 [[buffer(0)]],
                          device const float *omega [[buffer(1)]],
                          device float2 *spec [[buffer(2)]],
                          constant OceanParams &P [[buffer(3)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint N = P.N;
    if (gid.x >= N || gid.y >= N || gid.z >= P.cascades) return;
    uint idx = (gid.z * N + gid.y) * N + gid.x;
    float L = P.L[gid.z];
    float2 k = 2.0 * PI * (float2(gid.xy) - float(N / 2)) / L;
    float kl = length(k);
    float2 kn = kl > 1e-6 ? k / kl : float2(0.0);
    float4 hv = h0[idx];
    float ph = omega[idx] * P.time;
    float c = precise::cos(ph), s = precise::sin(ph);
    float2 h = cmul(hv.xy, float2(c, s)) + cmul(hv.zw, float2(c, -s));
    float2 ih = float2(-h.y, h.x);          // i·h
    float2 hDx = -ih * kn.x;                // -i kx/k h
    float2 hDz = -ih * kn.y;
    float2 hHx = ih * k.x;                  // i kx h
    float2 hHz = ih * k.y;
    float inv = kl > 1e-6 ? 1.0 / kl : 0.0;
    float2 hDxx = h * (k.x * k.x * inv);
    float2 hDzz = h * (k.y * k.y * inv);
    float2 hDxz = h * (k.x * k.y * inv);
    spec[idx * 4 + 0] = cpack(h, hDx);
    spec[idx * 4 + 1] = cpack(hDz, hHx);
    spec[idx * 4 + 2] = cpack(hHz, hDxx);
    spec[idx * 4 + 3] = cpack(hDzz, hDxz);
}

// One radix-2 inverse FFT line per threadgroup (N/2 threads), 4 complex fields at once, in threadgroup memory.
// vertical = 0 transforms rows, 1 transforms columns. grid: (N lines, cascades) threadgroups.
kernel void oceanFFT(device float2 *data [[buffer(0)]],
                     constant OceanParams &P [[buffer(1)]],
                     constant uint &vertical [[buffer(2)]],
                     uint2 tg [[threadgroup_position_in_grid]],
                     uint t [[thread_index_in_threadgroup]]) {
    threadgroup float2 buf[4][512];
    uint N = P.N, logN = P.logN, line = tg.x, c = tg.y;
    for (uint e = t; e < N; e += N / 2) {
        uint i = vertical ? ((c * N + e) * N + line) : ((c * N + line) * N + e);
        uint r = reverse_bits(e) >> (32 - logN);
        for (uint f = 0; f < 4; f++) buf[f][r] = data[i * 4 + f];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 1; s <= logN; s++) {
        uint m = 1u << s, hm = m >> 1;
        uint j = t & (hm - 1);
        uint i0 = (t >> (s - 1)) * m + j, i1 = i0 + hm;
        float ang = 2.0 * PI * float(j) / float(m);
        float2 w = float2(precise::cos(ang), precise::sin(ang));
        for (uint f = 0; f < 4; f++) {
            float2 a = buf[f][i0], b = cmul(buf[f][i1], w);
            buf[f][i0] = a + b; buf[f][i1] = a - b;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for (uint e = t; e < N; e += N / 2) {
        uint i = vertical ? ((c * N + e) * N + line) : ((c * N + line) * N + e);
        for (uint f = 0; f < 4; f++) data[i * 4 + f] = buf[f][e];
    }
}

// Sign-correct the centred spectrum, build displacement/derivative maps, Jacobian foam with temporal decay,
// and write both the textures (rendering) and shared buffers (CPU height queries).
kernel void oceanFinalize(device const float2 *data [[buffer(0)]],
                          device float *foam [[buffer(1)]],
                          device float4 *outDisp [[buffer(2)]],
                          device float4 *outDeriv [[buffer(3)]],
                          constant OceanParams &P [[buffer(4)]],
                          texture2d_array<float, access::write> dispTex [[texture(0)]],
                          texture2d_array<float, access::write> derivTex [[texture(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint N = P.N;
    if (gid.x >= N || gid.y >= N || gid.z >= P.cascades) return;
    uint idx = (gid.z * N + gid.y) * N + gid.x;
    float sg = ((gid.x + gid.y) & 1) ? -1.0 : 1.0;
    float2 v0 = data[idx * 4 + 0] * sg, v1 = data[idx * 4 + 1] * sg, v2 = data[idx * 4 + 2] * sg, v3 = data[idx * 4 + 3] * sg;
    float lam = P.choppy;
    float h = v0.x, dx = v0.y * lam, dz = v1.x * lam, hx = v1.y, hz = v2.x;
    float dxx = v2.y * lam, dzz = v3.x * lam, dxz = v3.y * lam;
    float J = (1.0 + dxx) * (1.0 + dzz) - dxz * dxz;
    float f = foam[idx] * exp(-P.dt / max(P.foamDecay, 1e-3));
    f = max(f, saturate((P.foamThreshold - J) * P.foamGain));
    foam[idx] = f;
    outDisp[idx] = float4(dx, h, dz, J);
    outDeriv[idx] = float4(hx, hz, dxx, dzz);
    dispTex.write(float4(dx, h, dz, f), gid.xy, gid.z);
    derivTex.write(float4(hx, hz, dxx, dzz), gid.xy, gid.z);
}
"""#

    // MARK: - Water surface rendering (ocean grid, lakes, rivers)
    static let surface = #"""
struct WaterVertex { packed_float3 pos; packed_float2 flow; float edge; };
struct WaterDraw {
    float4 origin;       // xyz camera-relative origin of the mesh, w wave amplitude scale
    float4 uvBase[3];    // xy frac(cameraXZ / L), w cascade fade distance (m)
    float4 L;            // patch sizes, w unused
    float4 depthTex;     // xy camera-relative xz of the depth texture min corner, z size (m, 0 = none), w refY - cameraY
    float4 absorb;       // rgb absorption (1/m), w scattering (1/m)
    float4 misc;         // x foam intensity, y time, z shoreline foam width (m), w underwater flag
    float4 scatter;      // rgb scattering albedo tint, w base roughness
};
struct WaterVOut {
    float4 position [[position]];
    float3 rel;
    float3 baseRel;
    float2 flow;
    float edge;
};

inline float cascadeFade(constant WaterDraw &d, int c, float dist, float mul) {
    float e = d.uvBase[c].w * mul;
    return 1.0 - smoothstep(e * 0.5, e, dist);
}

vertex WaterVOut waterVertex(uint vid [[vertex_id]],
                             device const WaterVertex *verts [[buffer(0)]],
                             constant FrameUniforms &f [[buffer(2)]],
                             constant WaterDraw &d [[buffer(3)]],
                             texture2d_array<float> disp [[texture(0)]]) {
    WaterVertex v = verts[vid];
    float3 p = d.origin.xyz + float3(v.pos);
    float dist = length(p.xz);
    constexpr sampler s(filter::linear, address::repeat);
    float3 D = float3(0.0);
    for (int c = 0; c < 3; c++) {
        float fade = cascadeFade(d, c, dist, 1.0);
        if (fade <= 0.0) continue;
        float2 uv = d.uvBase[c].xy + p.xz / d.L[c];
        D += disp.sample(s, uv, uint(c), level(0.0)).xyz * fade;
    }
    D *= d.origin.w * v.edge;
    WaterVOut o;
    o.baseRel = p;
    o.rel = p + D;
    o.flow = float2(v.flow);
    o.edge = v.edge;
    o.position = f.viewProj * float4(o.rel, 1.0);
    return o;
}

struct CascadeSample { float2 slope; float foam; };

inline CascadeSample sampleCascades(constant WaterDraw &d, texture2d_array<float> disp, texture2d_array<float> deriv,
                                    float2 xz, float2 offset, float dist) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    CascadeSample r; r.slope = float2(0.0); r.foam = 0.0;
    for (int c = 0; c < 3; c++) {
        float fade = cascadeFade(d, c, dist, 4.0);
        if (fade <= 0.0) continue;
        float2 uv = d.uvBase[c].xy + (xz + offset) / d.L[c];
        float4 dv = deriv.sample(s, uv, uint(c));
        r.slope += float2(dv.x / max(1.0 + dv.z, 0.2), dv.y / max(1.0 + dv.w, 0.2)) * fade;
        r.foam += disp.sample(s, uv, uint(c)).w * fade;
    }
    return r;
}

inline float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
inline float vnoise(float2 p) {
    float2 i = floor(p), fr = fract(p); float2 u = fr * fr * (3.0 - 2.0 * fr);
    return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x), mix(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}

// Shared physically based water shading. Returns premultiplied colour + coverage.
inline float4 shadeWater(constant FrameUniforms &f, depth2d_array<float> shadowMap, texture2d<float> skyLUT,
                         float3 rel, float3 N, float waterDepth, float foamAmount, float crest,
                         float3 absorb, float scatterCoeff, float3 scatterTint, float roughness, bool underwater) {
    float3 V = normalize(-rel);
    if (underwater) N = -N;
    float NoV = saturate(dot(N, V));
    float3 Ls = f.sunDir.xyz;
    float3 skyScale = f.sunColor.rgb * f.sunDir.w;
    float3 sunE = skyScale * transmittanceToSun(planetPos(f, rel), Ls);
    // Fresnel for air→water (n = 1.333); underwater: total internal reflection beyond the critical angle.
    float F = 0.02 + 0.98 * pow(1.0 - NoV, 5.0);
    float sinI = sqrt(saturate(1.0 - NoV * NoV));
    float eta = underwater ? 1.333 : 1.0 / 1.333;
    float sinT = sinI * eta;
    if (sinT >= 1.0) F = 1.0;
    float cosT = sqrt(saturate(1.0 - sinT * sinT));

    float3 R = reflect(-V, N);
    R.y = underwater ? R.y : abs(R.y);
    float3 refl = underwater ? scatterTint * 0.02 * skyScale : sampleSky(skyLUT, R) * skyScale;

    float viewDepth = dot(rel, f.cameraForward.xyz);
    float NoL = saturate(dot(N, Ls));
    float shadow = NoL > 0.0 ? sampleShadow(f, shadowMap, rel, N, viewDepth) : 0.0;
    float a = max(roughness * roughness, 0.0015);
    float3 H = normalize(V + Ls);
    float NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
    float Fs = 0.02 + 0.98 * pow(1.0 - VoH, 5.0);
    float3 spec = underwater ? float3(0.0) : D_GGX(NoH, a) * V_SmithGGXCorrelated(max(NoV, 1e-3), NoL, a) * Fs * sunE * NoL * shadow;

    // Water column: absorption + single scattering. Light reaching the bottom travels depth/cos(sun) down and
    // depth/cos(θt) back up; the opaque pass already rendered the bottom under full sun, so it is attenuated by T.
    float3 sigmaT = absorb + scatterCoeff;
    float sunCos = max(Ls.y, 0.1);
    float pathLen = waterDepth * (1.0 / max(cosT, 0.12) + 1.0 / sunCos);
    float3 T = exp(-sigmaT * min(pathLen, 500.0));
    float3 ambientSky = sampleSky(skyLUT, float3(0, 1, 0)) * skyScale * PI * 0.5;
    float3 albedoSS = scatterCoeff / sigmaT * scatterTint;
    float3 inscatter = albedoSS * (sunE * max(Ls.y, 0.0) * mix(0.6, 1.0, shadow) * 0.25 + ambientSky * 0.25) * (1.0 - T) / PI;
    // Sub-surface glow through thin wave crests when looking toward the sun (Atlas / Sea of Thieves style).
    float3 Lflat = normalize(float3(-Ls.x, 0.2, -Ls.z));
    float sss = pow(saturate(dot(V, Lflat)), 4.0) * saturate(crest * 0.35) * (1.0 - NoV * 0.5);
    inscatter += albedoSS * sunE * sss * 0.08;

    float3 color = refl * F + spec + (1.0 - F) * inscatter;
    float alpha = 1.0 - (1.0 - F) * dot(T, float3(1.0 / 3.0));

    // Foam: rough diffuse white, lit by sun + sky.
    float3 foamLit = 0.85 * (sunE * NoL * shadow + ambientSky) / PI;
    float fa = saturate(foamAmount);
    color = mix(color, foamLit, fa);
    alpha = mix(alpha, 1.0, fa);

    float3 Ta; float3 La = aerialPerspective(f, rel, Ta);
    color = color * Ta + La * alpha;
    return float4(color, alpha);
}

fragment float4 waterFragment(WaterVOut in [[stage_in]],
                              bool front [[front_facing]],
                              constant FrameUniforms &f [[buffer(2)]],
                              constant WaterDraw &d [[buffer(3)]],
                              depth2d_array<float> shadowMap [[texture(0)]],
                              texture2d<float> skyLUT [[texture(1)]],
                              texture2d_array<float> disp [[texture(2)]],
                              texture2d_array<float> deriv [[texture(3)]],
                              texture2d<float> depthTex [[texture(4)]]) {
    float3 rel = in.rel;
    float dist = length(rel);
    float2 xz = in.baseRel.xz;
    float time = d.misc.y;
    CascadeSample cs;
    float flowLen = length(in.flow);
    if (flowLen > 0.01) {
        // Two-phase flow-map advection of the wave detail (Vlachos 2010).
        float ph0 = fract(time * 0.25), ph1 = fract(time * 0.25 + 0.5);
        float wgt = abs(1.0 - 2.0 * ph0);
        CascadeSample a = sampleCascades(d, disp, deriv, xz, -in.flow * ph0 * 4.0, dist);
        CascadeSample b = sampleCascades(d, disp, deriv, xz, -in.flow * ph1 * 4.0 + float2(7.3, 3.1), dist);
        cs.slope = mix(b.slope, a.slope, wgt); cs.foam = mix(b.foam, a.foam, wgt);
        cs.foam += saturate(flowLen * 0.15) * vnoise((xz - in.flow * time) * 0.8) * 0.5;   // turbulent whitewater
    } else {
        cs = sampleCascades(d, disp, deriv, xz, float2(0.0), dist);
    }
    float amp = d.origin.w * in.edge;
    float3 N = normalize(float3(-cs.slope.x * amp, 1.0, -cs.slope.y * amp));
    N = normalize(mix(N, float3(0, 1, 0), saturate(dist / 30000.0)));

    float waterDepth = 1e4;
    if (d.depthTex.z > 0.0) {
        float2 uvD = (xz - d.depthTex.xy) / d.depthTex.z;
        if (all(uvD > 0.0) && all(uvD < 1.0)) {
            constexpr sampler ls(filter::linear, address::clamp_to_edge);
            float ground = depthTex.sample(ls, uvD).r + d.depthTex.w;
            waterDepth = max(rel.y - ground, 0.0);
        }
    }
    if (waterDepth <= 0.001 && d.depthTex.z > 0.0) discard_fragment();
    float shore = d.misc.z > 0.0 ? saturate(1.0 - waterDepth / d.misc.z) : 0.0;
    float shoreFoam = shore * smoothstep(0.35, 0.75, vnoise(xz * 1.7 + time * 0.6) * 0.6 + 0.5 * sin(time * 1.3 - waterDepth * 6.0) * 0.5 + 0.2);
    float foam = cs.foam * d.misc.x * amp + shoreFoam;
    float roughness = min(d.scatter.w + dist * 2e-5, 0.35);
    float crest = rel.y - in.baseRel.y;
    float4 c = shadeWater(f, shadowMap, skyLUT, rel, N, waterDepth, foam, crest, d.absorb.rgb, d.absorb.w, d.scatter.rgb,
                          roughness, !front || d.misc.w > 0.5);
    // Soft edge where the surface meets the shore (depth fade) and river banks.
    float edgeFade = saturate(waterDepth * 4.0) * saturate(in.edge * 4.0 + 0.0001 + (flowLen > 0.01 ? 0.0 : 1.0));
    return c * edgeFade;
}

// MARK: splash / spray particles (camera-facing billboards)
struct SplashVOut { float4 position [[position]]; float2 uv; float alpha; float3 rel; };
vertex SplashVOut splashVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               device const float4 *inst [[buffer(0)]],
                               constant FrameUniforms &f [[buffer(2)]]) {
    float4 ps = inst[iid * 2], misc = inst[iid * 2 + 1];
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid];
    float3 right = float3(f.view[0][0], f.view[1][0], f.view[2][0]);
    float3 up = float3(f.view[0][1], f.view[1][1], f.view[2][1]);
    float3 p = ps.xyz + (right * c.x + up * c.y) * ps.w;
    SplashVOut o;
    o.position = f.viewProj * float4(p, 1.0);
    o.uv = c; o.alpha = misc.x; o.rel = p;
    return o;
}
fragment float4 splashFragment(SplashVOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]], texture2d<float> skyLUT [[texture(1)]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0) discard_fragment();
    float a = in.alpha * (1.0 - r2) * (1.0 - r2);
    float3 skyScale = f.sunColor.rgb * f.sunDir.w;
    float3 sunE = skyScale * transmittanceToSun(planetPos(f, in.rel), f.sunDir.xyz);
    float3 amb = sampleSky(skyLUT, float3(0, 1, 0)) * skyScale * PI * 0.5;
    float3 c = 0.8 * (sunE * 0.6 + amb) / PI;
    return float4(c * a, a);
}
"""#

    // MARK: - FLIP/PIC local fluid zone
    static let fluid = #"""
struct FluidParams {
    uint4 dims;       // nx, ny, nz, particle count
    float4 domain;    // h (cell size), dt, flip ratio, gravity (m/s², negative)
    float4 misc;      // obstacle count, density (kg/m³), SOR ω, particles per cell
};
struct FluidObstacle { float4 center; float4 rot; float4 halfExt; float4 lin; float4 ang; };

constant uint T_AIR = 0, T_FLUID = 1, T_WALL = 2, T_OBST = 3;   // obstacle i → T_OBST + i

inline float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
inline float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }
inline uint cellIdx(int3 c, uint4 d) { return uint(c.x) + d.x * (uint(c.y) + d.y * uint(c.z)); }
inline uint faceIdx(int3 c, uint3 fd) { return uint(c.x) + fd.x * (uint(c.y) + fd.y * uint(c.z)); }

inline void splat(device atomic_float *sum, device atomic_float *wsum, float3 g, uint3 fd, float val) {
    int3 b = int3(floor(g)); float3 fr = g - float3(b);
    for (int dz = 0; dz < 2; dz++) for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
        int3 c = b + int3(dx, dy, dz);
        if (any(c < 0) || any(c >= int3(fd))) continue;
        float w = (dx ? fr.x : 1.0 - fr.x) * (dy ? fr.y : 1.0 - fr.y) * (dz ? fr.z : 1.0 - fr.z);
        uint i = faceIdx(c, fd);
        atomic_fetch_add_explicit(&sum[i], w * val, memory_order_relaxed);
        if (wsum) atomic_fetch_add_explicit(&wsum[i], w, memory_order_relaxed);
    }
}

inline float sampleFace(device const float *a, float3 g, uint3 fd) {
    g = clamp(g, float3(0.0), float3(fd) - 1.0001);
    int3 b = int3(floor(g)); float3 fr = g - float3(b);
    float r = 0.0;
    for (int dz = 0; dz < 2; dz++) for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
        int3 c = min(b + int3(dx, dy, dz), int3(fd) - 1);
        float w = (dx ? fr.x : 1.0 - fr.x) * (dy ? fr.y : 1.0 - fr.y) * (dz ? fr.z : 1.0 - fr.z);
        r += w * a[faceIdx(c, fd)];
    }
    return r;
}
inline float3 sampleVel(device const float *u, device const float *v, device const float *w, float3 x, uint4 d) {
    return float3(sampleFace(u, x - float3(0.0, 0.5, 0.5), uint3(d.x + 1, d.y, d.z)),
                  sampleFace(v, x - float3(0.5, 0.0, 0.5), uint3(d.x, d.y + 1, d.z)),
                  sampleFace(w, x - float3(0.5, 0.5, 0.0), uint3(d.x, d.y, d.z + 1)));
}

kernel void fluidP2G(device const float4 *pos [[buffer(0)]], device const float4 *vel [[buffer(1)]],
                     device atomic_float *uS [[buffer(2)]], device atomic_float *uW [[buffer(3)]],
                     device atomic_float *vS [[buffer(4)]], device atomic_float *vW [[buffer(5)]],
                     device atomic_float *wS [[buffer(6)]], device atomic_float *wW [[buffer(7)]],
                     device atomic_float *dens [[buffer(8)]], device atomic_uint *count [[buffer(9)]],
                     constant FluidParams &P [[buffer(10)]], uint id [[thread_position_in_grid]]) {
    if (id >= P.dims.w) return;
    uint4 d = P.dims;
    float3 x = pos[id].xyz / P.domain.x;
    float3 v = vel[id].xyz;
    splat(uS, uW, x - float3(0.0, 0.5, 0.5), uint3(d.x + 1, d.y, d.z), v.x);
    splat(vS, vW, x - float3(0.5, 0.0, 0.5), uint3(d.x, d.y + 1, d.z), v.y);
    splat(wS, wW, x - float3(0.5, 0.5, 0.0), uint3(d.x, d.y, d.z + 1), v.z);
    splat(dens, nullptr, x - 0.5, d.xyz, 1.0);
    int3 c = clamp(int3(floor(x)), int3(0), int3(d.xyz) - 1);
    atomic_fetch_add_explicit(&count[cellIdx(c, d)], 1u, memory_order_relaxed);
}

kernel void fluidNormalize(device const float *sum [[buffer(0)]], device const float *wsum [[buffer(1)]],
                           device float *velOut [[buffer(2)]], device float *velOld [[buffer(3)]],
                           constant uint &n [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    if (id >= n) return;
    float w = wsum[id];
    float v = w > 1e-6 ? sum[id] / w : 0.0;
    velOut[id] = v; velOld[id] = v;
}

kernel void fluidClassify(device const uint *count [[buffer(0)]], device const float *dens [[buffer(1)]],
                          device uint *type [[buffer(2)]], device float *pressure [[buffer(3)]],
                          device const FluidObstacle *obs [[buffer(4)]], constant FluidParams &P [[buffer(5)]],
                          texture3d<float, access::write> densTex [[texture(0)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint4 d = P.dims;
    if (any(gid >= d.xyz)) return;
    int3 c = int3(gid);
    uint i = cellIdx(c, d);
    uint t = count[i] > 0 ? T_FLUID : T_AIR;
    if (c.x == 0 || c.y == 0 || c.z == 0 || c.x == int(d.x) - 1 || c.z == int(d.z) - 1) t = T_WALL;   // top is open
    float3 p = (float3(gid) + 0.5) * P.domain.x;
    for (uint o = 0; o < uint(P.misc.x); o++) {
        float3 l = qrotInv(obs[o].rot, p - obs[o].center.xyz);
        if (all(abs(l) < obs[o].halfExt.xyz)) t = T_OBST + o;
    }
    type[i] = t;
    if (t != T_FLUID) pressure[i] = 0.0;
    densTex.write(float4(dens[i] / max(P.misc.w, 1.0)), gid);
}

inline float solidVel(uint t, float3 p, uint comp, device const FluidObstacle *obs) {
    if (t < T_OBST) return 0.0;
    FluidObstacle o = obs[t - T_OBST];
    float3 v = o.lin.xyz + cross(o.ang.xyz, p - o.center.xyz);
    return v[comp];
}

// Gravity + solid boundary conditions on one face component (comp 0 = u, 1 = v, 2 = w).
kernel void fluidForces(device float *vel [[buffer(0)]], device const uint *type [[buffer(1)]],
                        device const FluidObstacle *obs [[buffer(2)]], constant FluidParams &P [[buffer(3)]],
                        constant uint &comp [[buffer(4)]], uint3 gid [[thread_position_in_grid]]) {
    uint4 d = P.dims;
    uint3 fd = d.xyz; fd[comp] += 1;
    if (any(gid >= fd)) return;
    int3 c = int3(gid);
    uint i = faceIdx(c, fd);
    if (c[comp] == 0 || c[comp] == int(d[comp])) { vel[i] = 0.0; return; }
    int3 cl = c; cl[comp] -= 1;
    uint tl = type[cellIdx(cl, d)], tr = type[cellIdx(c, d)];
    float3 p = float3(c) + 0.5; p[comp] -= 0.5; p *= P.domain.x;
    if (tl >= T_WALL || tr >= T_WALL) { vel[i] = solidVel(max(tl, tr) >= T_OBST ? max(tl, tr) : T_WALL, p, comp, obs); return; }
    if (comp == 1) vel[i] += P.domain.w * P.domain.y;
}

kernel void fluidDivergence(device const float *u [[buffer(0)]], device const float *v [[buffer(1)]], device const float *w [[buffer(2)]],
                            device const uint *type [[buffer(3)]], device float *div [[buffer(4)]], constant FluidParams &P [[buffer(5)]],
                            uint3 gid [[thread_position_in_grid]]) {
    uint4 d = P.dims;
    if (any(gid >= d.xyz)) return;
    int3 c = int3(gid);
    uint i = cellIdx(c, d);
    if (type[i] != T_FLUID) { div[i] = 0.0; return; }
    uint3 fu = uint3(d.x + 1, d.y, d.z), fv = uint3(d.x, d.y + 1, d.z), fw = uint3(d.x, d.y, d.z + 1);
    float dv = u[faceIdx(c + int3(1, 0, 0), fu)] - u[faceIdx(c, fu)]
             + v[faceIdx(c + int3(0, 1, 0), fv)] - v[faceIdx(c, fv)]
             + w[faceIdx(c + int3(0, 0, 1), fw)] - w[faceIdx(c, fw)];
    div[i] = dv / P.domain.x;
}

// Red-black SOR Gauss-Seidel for ∇²q = ∇·u (q = p·dt/ρ), air q = 0, solid Neumann.
kernel void fluidPressure(device float *q [[buffer(0)]], device const float *div [[buffer(1)]], device const uint *type [[buffer(2)]],
                          constant FluidParams &P [[buffer(3)]], constant uint &parity [[buffer(4)]], uint3 gid [[thread_position_in_grid]]) {
    uint4 d = P.dims;
    // Dispatched over (nx/2, ny, nz): each thread owns the cell of the requested colour in its x pair.
    uint x = gid.x * 2 + ((gid.y + gid.z + parity) & 1);
    if (x >= d.x || gid.y >= d.y || gid.z >= d.z) return;
    int3 c = int3(x, gid.y, gid.z);
    uint i = cellIdx(c, d);
    if (type[i] != T_FLUID) return;
    float sum = 0.0; float n = 0.0;
    const int3 nb[6] = { int3(1,0,0), int3(-1,0,0), int3(0,1,0), int3(0,-1,0), int3(0,0,1), int3(0,0,-1) };
    for (int k = 0; k < 6; k++) {
        int3 cc = c + nb[k];
        if (any(cc < 0) || any(cc >= int3(d.xyz))) { n += 1.0; continue; }   // open top boundary → air
        uint t = type[cellIdx(cc, d)];
        if (t >= T_WALL) continue;
        n += 1.0;
        if (t == T_FLUID) sum += q[cellIdx(cc, d)];
    }
    if (n == 0.0) return;
    float h = P.domain.x;
    float qn = (sum - div[i] * h * h) / n;
    q[i] = mix(q[i], qn, P.misc.z);
}

// Subtract ∇q on one face component; accumulate pressure force/torque on obstacles (two-way coupling).
kernel void fluidProject(device float *vel [[buffer(0)]], device const float *q [[buffer(1)]], device const uint *type [[buffer(2)]],
                         device const FluidObstacle *obs [[buffer(3)]], device atomic_float *obsForce [[buffer(4)]],
                         constant FluidParams &P [[buffer(5)]], constant uint &comp [[buffer(6)]], uint3 gid [[thread_position_in_grid]]) {
    uint4 d = P.dims;
    uint3 fd = d.xyz; fd[comp] += 1;
    if (any(gid >= fd)) return;
    int3 c = int3(gid);
    if (c[comp] == 0 || c[comp] == int(d[comp])) return;
    uint i = faceIdx(c, fd);
    int3 cl = c; cl[comp] -= 1;
    uint il = cellIdx(cl, d), ir = cellIdx(c, d);
    uint tl = type[il], tr = type[ir];
    float h = P.domain.x;
    if (tl >= T_WALL || tr >= T_WALL) {
        // Fluid pressing on an obstacle face: F = p·A·n, p = q·ρ/dt.
        bool lf = tl == T_FLUID && tr >= T_OBST, rf = tr == T_FLUID && tl >= T_OBST;
        if (lf || rf) {
            uint ot = (lf ? tr : tl) - T_OBST;
            float p = (lf ? q[il] : q[ir]) * P.misc.y / P.domain.y;
            float3 dir = float3(0.0); dir[comp] = lf ? 1.0 : -1.0;
            float3 F = dir * p * h * h;
            float3 pos = float3(c) + 0.5; pos[comp] -= 0.5; pos *= h;
            float3 tq = cross(pos - obs[ot].center.xyz, F);
            device atomic_float *o = obsForce + ot * 8;
            atomic_fetch_add_explicit(&o[0], F.x, memory_order_relaxed);
            atomic_fetch_add_explicit(&o[1], F.y, memory_order_relaxed);
            atomic_fetch_add_explicit(&o[2], F.z, memory_order_relaxed);
            atomic_fetch_add_explicit(&o[3], tq.x, memory_order_relaxed);
            atomic_fetch_add_explicit(&o[4], tq.y, memory_order_relaxed);
            atomic_fetch_add_explicit(&o[5], tq.z, memory_order_relaxed);
        }
        return;
    }
    if (tl != T_FLUID && tr != T_FLUID) return;
    float ql = tl == T_FLUID ? q[il] : 0.0, qr = tr == T_FLUID ? q[ir] : 0.0;
    vel[i] -= (qr - ql) / h;
}

kernel void fluidG2P(device float4 *pos [[buffer(0)]], device float4 *vel [[buffer(1)]],
                     device const float *u [[buffer(2)]], device const float *v [[buffer(3)]], device const float *w [[buffer(4)]],
                     device const float *uo [[buffer(5)]], device const float *vo [[buffer(6)]], device const float *wo [[buffer(7)]],
                     device const FluidObstacle *obs [[buffer(8)]], constant FluidParams &P [[buffer(9)]],
                     device atomic_uint *maxSpeedBits [[buffer(10)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= P.dims.w) return;
    uint4 d = P.dims;
    float h = P.domain.x, dt = P.domain.y;
    float3 xp = pos[id].xyz;
    float3 x = xp / h;
    float3 vn = sampleVel(u, v, w, x, d);
    float3 vold = sampleVel(uo, vo, wo, x, d);
    float3 vp = vel[id].xyz;
    float3 vflip = vp + (vn - vold);
    vp = mix(vn, vflip, P.domain.z);
    // RK2 advection through the grid velocity.
    float3 mid = xp + 0.5 * dt * vn;
    float3 vm = sampleVel(u, v, w, mid / h, d);
    xp += dt * vm;
    float3 lo = float3(h * 1.001), hi = float3(d.xyz) * h - h * 1.001;
    hi.y = float(d.y) * h - h * 0.001;
    for (int k = 0; k < 3; k++) {
        if (xp[k] < lo[k]) { xp[k] = lo[k]; vp[k] = max(vp[k], 0.0); }
        if (xp[k] > hi[k]) { xp[k] = hi[k]; vp[k] = min(vp[k], 0.0); }
    }
    for (uint o = 0; o < uint(P.misc.x); o++) {
        FluidObstacle ob = obs[o];
        float3 l = qrotInv(ob.rot, xp - ob.center.xyz);
        float3 he = ob.halfExt.xyz + h * 0.25;
        if (all(abs(l) < he)) {
            float3 pen = he - abs(l);
            int ax = pen.x < pen.y ? (pen.x < pen.z ? 0 : 2) : (pen.y < pen.z ? 1 : 2);
            l[ax] = sign(l[ax]) * he[ax];
            xp = ob.center.xyz + qrot(ob.rot, l);
            float3 nW = float3(0.0); nW[ax] = sign(l[ax]); nW = qrot(ob.rot, nW);
            float3 vs = ob.lin.xyz + cross(ob.ang.xyz, xp - ob.center.xyz);
            float rel = dot(vp - vs, nW);
            if (rel < 0.0) vp -= rel * nW;
        }
    }
    if (any(isnan(xp)) || any(isnan(vp))) { xp = float3(d.xyz) * h * 0.5; vp = float3(0.0); }
    pos[id] = float4(xp, 1.0);
    vel[id] = float4(vp, 0.0);
    atomic_fetch_max_explicit(maxSpeedBits, as_type<uint>(length(vp)), memory_order_relaxed);   // positive floats order as uints
}

"""#

    // MARK: - fluid zone surface rendering (needs `surface` for shadeWater)
    static let fluidRender = #"""
// MARK: fluid surface rendering — ray-march the splatted density field.
struct FluidDraw { float4 originRel; float4 size; float4 absorb; float4 params; };   // params: x cell size (m), y iso
struct FluidVOut { float4 position [[position]]; float3 rel; };
struct FluidFOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

vertex FluidVOut fluidBoxVertex(uint vid [[vertex_id]], constant FrameUniforms &f [[buffer(2)]], constant FluidDraw &d [[buffer(3)]]) {
    const uint idx[36] = { 0,2,1, 1,2,3, 4,5,6, 5,7,6, 0,1,4, 1,5,4, 2,6,3, 3,6,7, 0,4,2, 2,4,6, 1,3,5, 3,7,5 };
    uint c = idx[vid];
    float3 corner = float3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
    FluidVOut o;
    o.rel = d.originRel.xyz + corner * d.size.xyz;
    o.position = f.viewProj * float4(o.rel, 1.0);
    return o;
}

fragment FluidFOut fluidBoxFragment(FluidVOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]], constant FluidDraw &d [[buffer(3)]],
                                    depth2d_array<float> shadowMap [[texture(0)]], texture2d<float> skyLUT [[texture(1)]],
                                    texture3d<float> dens [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 rd = normalize(in.rel);
    float3 bmin = d.originRel.xyz, bmax = bmin + d.size.xyz;
    float3 inv = 1.0 / rd;
    float3 t0 = bmin * inv, t1 = bmax * inv;
    float tn = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    float tf = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    tn = max(tn, f.cameraForward.w);
    if (tf <= tn) discard_fragment();
    float stepLen = d.params.x * 0.5;
    float iso = d.params.y;
    float t = tn, prevT = tn; bool hit = false;
    int maxSteps = int(min((tf - tn) / stepLen, 400.0)) + 1;
    for (int k = 0; k < maxSteps; k++) {
        float3 uvw = (rd * t - bmin) / d.size.xyz;
        if (dens.sample(s, uvw).r > iso) { hit = true; break; }
        prevT = t; t += stepLen;
    }
    if (!hit) discard_fragment();
    float a = prevT, b = t;
    for (int k = 0; k < 5; k++) {
        float m = 0.5 * (a + b);
        if (dens.sample(s, (rd * m - bmin) / d.size.xyz).r > iso) b = m; else a = m;
    }
    float3 hitRel = rd * b;
    float3 uvw = (hitRel - bmin) / d.size.xyz;
    float3 e = 1.0 / float3(dens.get_width(), dens.get_height(), dens.get_depth());
    float3 g = float3(dens.sample(s, uvw + float3(e.x, 0, 0)).r - dens.sample(s, uvw - float3(e.x, 0, 0)).r,
                      dens.sample(s, uvw + float3(0, e.y, 0)).r - dens.sample(s, uvw - float3(0, e.y, 0)).r,
                      dens.sample(s, uvw + float3(0, 0, e.z)).r - dens.sample(s, uvw - float3(0, 0, e.z)).r);
    float3 N = length(g) > 1e-5 ? -normalize(g) : float3(0, 1, 0);
    // Thickness along the refracted ray (approximated by the view ray) for Beer–Lambert absorption.
    float thick = 0.0; float tt = b;
    for (int k = 0; k < 48 && tt < tf; k++) {
        if (dens.sample(s, (rd * tt - bmin) / d.size.xyz).r > iso) thick += stepLen * 2.0;
        tt += stepLen * 2.0;
    }
    float4 c = shadeWater(f, shadowMap, skyLUT, hitRel, N, thick * 0.5, 0.0, 0.0, d.absorb.rgb, d.absorb.w, float3(0.7, 0.9, 1.0), 0.04, false);
    // White-water where the surface is strongly curved / fragmented.
    float frag = saturate(1.0 - length(g) * 3.0);
    c.rgb = mix(c.rgb, float3(0.8) * c.a, frag * 0.3);
    // Blend the zone into the surrounding water near its vertical walls (the zone is a local window, not a tank).
    float3 lp = hitRel - bmin;
    float border = min(min(lp.x, d.size.x - lp.x), min(lp.z, d.size.z - lp.z));
    c *= smoothstep(d.params.x * 1.0, d.params.x * 6.0, border);
    FluidFOut o;
    o.color = c;
    float4 clip = f.viewProj * float4(hitRel, 1.0);
    o.depth = clip.z / clip.w;
    return o;
}
"""#
}
