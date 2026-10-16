// OWNED BY terrain builder.
// Terrain MSL (compiled at runtime with ShaderCommon.header prepended):
//  - CDLOD vertex shader: GPU height displacement from an r32Float heightmap + continuous geomorphing
//  - shadow vertex shader for the cascades
//  - fragment: macro normals, splat weights, height-blended triplanar PBR detail layers, aerial perspective
//  - compute: normal/AO map from heights, procedural detail texture generation (startup)
enum TerrainShaders {
    static let source = #"""
struct TerrainU {
    float2 camLocal;      // camera xz relative to field origin
    float camY;           // camera absolute height
    float spacing;        // metres per heightfield sample
    float2 fieldSize;     // samples (w, h)
    float baseLevel;
    float falloff;
    float4 layerScale;    // metres per detail-texture repeat (grass, rock, dirt, snow)
    float4 misc;          // x sea level, y debug LOD colouring, z detail normal strength, w macro variation
    float4 macroOrigin;   // integer lattice index of texel (0,0) of the macro-noise hash textures: xy for /173 m, zw for /41 m
};
struct TerrainNode {
    float2 origin;        // field-local xz of grid vertex (0,0)
    float spacing;        // vertex spacing (m)
    float level;
    float morphStart;
    float morphEnd;
    float gridN;          // quads per side in this draw's mesh
    float pad;
};

inline float terrainHeight(texture2d<float> ht, constant TerrainU &t, float2 local) {
    float2 uv = local / t.spacing;
    float2 maxi = t.fieldSize - 1.0;
    float2 cu = clamp(uv, float2(0.0), maxi);
    float2 i0f = min(floor(cu), maxi - 1.0);
    uint2 i0 = uint2(i0f);
    float2 fr = cu - i0f;
    float h00 = ht.read(i0).r, h10 = ht.read(i0 + uint2(1, 0)).r;
    float h01 = ht.read(i0 + uint2(0, 1)).r, h11 = ht.read(i0 + uint2(1, 1)).r;
    float h = mix(mix(h00, h10, fr.x), mix(h01, h11, fr.x), fr.y);
    float d = length(uv - cu) * t.spacing;
    if (d > 0.0) h = mix(h, t.baseLevel, smoothstep(0.0, t.falloff, d));
    return h;
}

struct TerrainVOut {
    float4 position [[position]];
    float3 rel;
    float2 local;
    float lod;
};

inline float2 terrainMorphedLocal(TerrainNode n, uint vid, texture2d<float> ht, constant TerrainU &t, thread float &h) {
    uint N = uint(n.gridN);
    float2 g = float2(vid % (N + 1), vid / (N + 1));
    float2 local = n.origin + g * n.spacing;
    h = terrainHeight(ht, t, local);
    float3 rel = float3(local.x - t.camLocal.x, h - t.camY, local.y - t.camLocal.y);
    float k = saturate((length(rel) - n.morphStart) / max(n.morphEnd - n.morphStart, 1e-3));
    float2 fr = fract(g * 0.5) * 2.0;
    g -= fr * k;
    local = n.origin + g * n.spacing;
    h = terrainHeight(ht, t, local);
    return local;
}

vertex TerrainVOut terrainVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device TerrainNode *nodes [[buffer(1)]],
                                 constant FrameUniforms &f [[buffer(2)]],
                                 constant TerrainU &t [[buffer(4)]],
                                 texture2d<float> ht [[texture(0)]]) {
    TerrainNode n = nodes[iid];
    float h;
    float2 local = terrainMorphedLocal(n, vid, ht, t, h);
    float3 rel = float3(local.x - t.camLocal.x, h - t.camY, local.y - t.camLocal.y);
    TerrainVOut o;
    o.position = f.viewProj * float4(rel, 1.0);
    o.rel = rel; o.local = local; o.lod = n.level;
    return o;
}

struct TerrainShadowOut { float4 position [[position]]; };
vertex TerrainShadowOut terrainShadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                            const device TerrainNode *nodes [[buffer(1)]],
                                            constant FrameUniforms &f [[buffer(2)]],
                                            constant uint &cascade [[buffer(3)]],
                                            constant TerrainU &t [[buffer(4)]],
                                            texture2d<float> ht [[texture(0)]]) {
    float h;
    float2 local = terrainMorphedLocal(nodes[iid], vid, ht, t, h);
    float3 rel = float3(local.x - t.camLocal.x, h - t.camY, local.y - t.camLocal.y);
    TerrainShadowOut o;
    o.position = f.cascadeViewProj[cascade] * float4(rel, 1.0);
    o.position.z = max(o.position.z, 0.0);
    return o;
}

// ---------------------------------------------------------------- fragment
inline float tvhash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
inline float tvnoise(float2 p) {
    float2 i = floor(p), fr = fract(p); fr = fr * fr * (3.0 - 2.0 * fr);
    return mix(mix(tvhash(i), tvhash(i + float2(1, 0)), fr.x), mix(tvhash(i + float2(0, 1)), tvhash(i + float2(1, 1)), fr.x), fr.y);
}

// tvnoise() with the lattice hashes pre-baked (same tvhash values, one gather instead of four sin-hashes).
inline float tvnoiseBaked(texture2d<float> H, float2 p, float2 org) {
    constexpr sampler g(filter::nearest, address::clamp_to_edge);
    float2 i = floor(p), fr = fract(p); fr = fr * fr * (3.0 - 2.0 * fr);
    float4 q = H.gather(g, (i - org + 1.0) / float2(H.get_width(), H.get_height()));            // texels (i, i+1) of the 2x2 footprint around the shared corner
    return mix(mix(q.w, q.z, fr.x), mix(q.x, q.y, fr.x), fr.y);
}
// Per-layer maximum of the detail height channel (float bits compare like uints for non-negative values).
kernel void terrainHeightMax(texture2d_array<float, access::read> nh [[texture(0)]],
                             device atomic_uint *out [[buffer(0)]],
                             uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= nh.get_width() || gid.y >= nh.get_height()) return;
    float h = max(nh.read(gid.xy, gid.z).z, 0.0);
    atomic_fetch_max_explicit(&out[gid.z], as_type<uint>(h), memory_order_relaxed);
}
kernel void terrainMacroHash(texture2d<float, access::write> H [[texture(0)]],
                             constant float2 &org [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= H.get_width() || gid.y >= H.get_height()) return;
    H.write(float4(tvhash(float2(gid) + org)), gid);
}

struct TriSample { float4 albedo; float4 nh; };

// bw: projection weights (already thresholded/renormalised; zero planes are skipped entirely).
inline TriSample triplanar(texture2d_array<float> A, texture2d_array<float> NH, sampler s, float3 wp, float scale, uint layer, float3 bw) {
    TriSample r; r.albedo = 0.0; r.nh = 0.0;
    float inv = 1.0 / scale;
    float3 pert = 0.0;
    if (bw.y > 0.0) {
        float2 uv = wp.xz * inv;
        float4 a = A.sample(s, uv, layer), n = NH.sample(s, uv, layer);
        r.albedo += a * bw.y; r.nh.zw += n.zw * bw.y;
        pert += float3(n.x, 0.0, n.y) * bw.y;
    }
    if (bw.x > 0.0) {
        float2 uv = wp.zy * inv;
        float4 a = A.sample(s, uv, layer), n = NH.sample(s, uv, layer);
        r.albedo += a * bw.x; r.nh.zw += n.zw * bw.x;
        pert += float3(0.0, n.y, n.x) * bw.x;
    }
    if (bw.z > 0.0) {
        float2 uv = wp.xy * inv;
        float4 a = A.sample(s, uv, layer), n = NH.sample(s, uv, layer);
        r.albedo += a * bw.z; r.nh.zw += n.zw * bw.z;
        pert += float3(n.x, n.y, 0.0) * bw.z;
    }
    // detail-normal perturbation (xz of world space; the side planes' y term is negligible)
    r.nh = float4(pert.x, pert.z, r.nh.z, r.nh.w);
    return r;
}

fragment float4 terrainFragment(TerrainVOut in [[stage_in]],
                                constant FrameUniforms &f [[buffer(2)]],
                                constant TerrainU &t [[buffer(4)]],
                                depth2d_array<float> shadowMap [[texture(0)]],
                                texture2d<float> skyLUT [[texture(1)]],
                                texture2d<float> normalTex [[texture(2)]],
                                texture2d<float> splatTex [[texture(3)]],
                                texture2d_array<float> albedoArr [[texture(4)]],
                                texture2d_array<float> nhArr [[texture(5)]],
                                texture2d<float> macroA [[texture(6)]], texture2d<float> macroB [[texture(7)]],
                                const device float4 &hmax [[buffer(5)]],
                                texture3d<float> apL [[texture(13)]], texture3d<float> apT [[texture(14)]], texture3d<float> apS [[texture(15)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float2 uv = (in.local / t.spacing + 0.5) / t.fieldSize;
    float4 nm = normalTex.sample(lin, uv);
    float3 N = normalize(nm.xyz);
    float macroAO = nm.w;
    float4 w = splatTex.sample(lin, uv);
    // outside the field: fade to flat grass
    float2 cu = clamp(in.local / t.spacing, float2(0.0), t.fieldSize - 1.0);
    float outD = length(in.local / t.spacing - cu) * t.spacing;
    float outK = smoothstep(0.0, t.falloff, outD);
    N = normalize(mix(N, float3(0, 1, 0), outK));
    w = mix(w, float4(1, 0, 0, 0), outK);
    w /= max(dot(w, float4(1.0)), 1e-3);

    float3 wp = float3(in.local.x, in.rel.y + t.camY, in.local.y);
    // Triplanar weights: subtract a small floor and renormalise, so near-flat ground uses one projection
    // (2 fetches per layer instead of up to 6) while the blend stays continuous on slopes.
    float3 bw = pow(abs(N), float3(4.0)); bw /= dot(bw, float3(1.0));
    bw = max(bw - 0.04, 0.0); bw /= dot(bw, float3(1.0));
    float dist = length(in.rel);

    // Height-based blending keeps only layers with a = w + 0.45 h > max(a) - 0.18. hmax holds each layer's
    // largest detail height (measured from the generated texture; filtering and projection blends cannot exceed it),
    // so once the dominant layer is sampled any layer with w + 0.45 hmax <= a_dom - 0.18 has zero final weight:
    // skipping it is exact.
    uint dom = 0;
    for (uint l = 1; l < 4; l++) if (w[l] > w[dom]) dom = l;
    TriSample L[4];
    float4 hgt = 0.0;
    L[dom] = triplanar(albedoArr, nhArr, rep, wp, t.layerScale[dom], dom, bw); hgt[dom] = L[dom].nh.z;
    float4 live = step(0.004, w) * step(float4(w[dom] + hgt[dom] * 0.45 - 0.18), w + hmax * 0.45);
    live[dom] = 1.0;
    for (uint l = 0; l < 4; l++) {
        if (l == dom) continue;
        if (live[l] > 0.0) { L[l] = triplanar(albedoArr, nhArr, rep, wp, t.layerScale[l], l, bw); hgt[l] = L[l].nh.z; }
        else { L[l].albedo = 0.0; L[l].nh = 0.0; }
    }
    // height-based blending: higher detail texels poke through transitions
    float4 a = w + hgt * 0.45 * step(0.004, w);
    float ma = max(max(a.x, a.y), max(a.z, a.w)) - 0.18;
    float4 bwl = max(a - ma, 0.0) * step(0.004, w) * live;
    bwl /= max(dot(bwl, float4(1.0)), 1e-4);

    float3 albedo = 0.0; float rough = 0.0, ao = 0.0; float2 pert = 0.0;
    for (uint l = 0; l < 4; l++) {
        if (bwl[l] <= 0.0) continue;
        albedo += L[l].albedo.rgb * bwl[l]; rough += L[l].albedo.a * bwl[l];
        ao += L[l].nh.w * bwl[l]; pert += L[l].nh.xy * bwl[l];
    }
    // macro variation breaks tiling at distance
    float2 mp = in.local;
    float var1 = tvnoiseBaked(macroA, mp / 173.0, t.macroOrigin.xy) * 0.6 + tvnoiseBaked(macroB, mp / 41.0, t.macroOrigin.zw) * 0.4;
    albedo *= mix(1.0 - t.misc.w, 1.0 + t.misc.w, var1);
    // wet darkening near sea level
    float wet = 1.0 - smoothstep(t.misc.x, t.misc.x + 1.5, wp.y);
    albedo *= mix(1.0, 0.55, wet); rough = mix(rough, 0.25, wet * 0.8);

    float detailFade = 1.0 - smoothstep(600.0, 4000.0, dist);
    N = normalize(N + float3(pert.x, 0.0, pert.y) * t.misc.z * detailFade);

    if (t.misc.y > 0.5) {   // debug: tint by LOD level
        float3 c = float3(fract(in.lod * 0.37), fract(in.lod * 0.61 + 0.3), fract(in.lod * 0.13 + 0.6));
        albedo = mix(albedo, c, 0.6);
    }
    AerialSample ap = aerialLookup(f, apL, apT, apS, in.rel);
    float3 c = shadeSurfaceT(f, skyLUT, shadowMap, in.rel, N, albedo, clamp(rough, 0.05, 1.0), 0.0, ao * macroAO, ap.sunT);
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- compute: normals + cavity AO
inline float hread(texture2d<float, access::read> ht, int W, int H, int x, int y) { return ht.read(uint2(clamp(x, 0, W - 1), clamp(y, 0, H - 1))).r; }
kernel void terrainNormals(texture2d<float, access::read> ht [[texture(0)]],
                           texture2d<float, access::write> nt [[texture(1)]],
                           constant uint4 &rect [[buffer(0)]],
                           constant float &spacing [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 p = gid + rect.xy;
    if (p.x >= rect.z || p.y >= rect.w) return;
    int W = int(ht.get_width()), H = int(ht.get_height());
    int x = int(p.x), y = int(p.y);
    float hL = hread(ht, W, H, x - 1, y), hR = hread(ht, W, H, x + 1, y), hT = hread(ht, W, H, x, y - 1), hB = hread(ht, W, H, x, y + 1), h = hread(ht, W, H, x, y);
    float3 n = normalize(float3(hL - hR, 2.0 * spacing, hT - hB));
    // cavity: average of a wider ring vs centre
    float avg = 0.0;
    for (int dy = -2; dy <= 2; dy += 2) for (int dx = -2; dx <= 2; dx += 2) avg += hread(ht, W, H, x + dx, y + dy);
    avg = (avg - h) / 8.0;
    float ao = clamp(1.0 - max(0.0, avg - h) / (spacing * 0.8), 0.55, 1.0);
    nt.write(float4(n, ao), p);
}

// ---------------------------------------------------------------- compute: procedural detail textures
inline float dhash(int2 p, int seed) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + uint(seed) * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u; h ^= h >> 16;
    return float(h & 0xffffffu) / 16777215.0;
}
inline float phash(int2 q, int period, int seed) { return dhash(int2(((q.x % period) + period) % period, ((q.y % period) + period) % period), seed); }
inline float pnoise(float2 p, int period, int seed) {
    int2 i = int2(floor(p)); float2 fr = fract(p); fr = fr * fr * (3.0 - 2.0 * fr);
    return mix(mix(phash(i, period, seed), phash(i + int2(1, 0), period, seed), fr.x),
               mix(phash(i + int2(0, 1), period, seed), phash(i + int2(1, 1), period, seed), fr.x), fr.y);
}
inline float tfbm(float2 uv, int baseFreq, int octaves, int seed) {
    float s = 0.0, a = 0.5, n = 0.0; int fq = baseFreq;
    for (int o = 0; o < octaves; o++) { s += a * pnoise(uv * float(fq), fq, seed + o * 31); n += a; a *= 0.5; fq *= 2; }
    return s / n;
}
inline float layerHeight(uint l, float2 uv) {
    if (l == 0) { // grass: clumps + blades
        return tfbm(uv, 8, 5, 11) * 0.55 + tfbm(uv, 64, 3, 12) * 0.45;
    } else if (l == 1) { // rock: ridged + strata + cracks
        float r = 1.0 - abs(tfbm(uv, 4, 6, 21) * 2.0 - 1.0);
        float strata = 0.5 + 0.5 * sin((uv.y + tfbm(uv, 4, 3, 22) * 0.25) * 2.0 * PI * 10.0);
        float cracks = smoothstep(0.0, 0.06, abs(tfbm(uv, 8, 4, 23) - 0.5));
        return (r * 0.6 + strata * 0.25 + tfbm(uv, 32, 3, 24) * 0.15) * mix(0.6, 1.0, cracks);
    } else if (l == 2) { // dirt/sand: ripples + pebbles
        float pebbles = smoothstep(0.62, 0.8, tfbm(uv, 32, 2, 31));
        return tfbm(uv, 16, 5, 32) * 0.7 + pebbles * 0.5;
    }
    return tfbm(uv, 4, 5, 41) * 0.8 + tfbm(uv, 32, 3, 42) * 0.2;   // snow: soft drifts
}
kernel void terrainDetailGen(texture2d_array<float, access::write> albedo [[texture(0)]],
                             texture2d_array<float, access::write> nh [[texture(1)]],
                             uint3 gid [[thread_position_in_grid]]) {
    uint S = albedo.get_width();
    if (gid.x >= S || gid.y >= S) return;
    uint l = gid.z;
    float2 uv = (float2(gid.xy) + 0.5) / float(S);
    float e = 1.0 / float(S);
    float h = layerHeight(l, uv);
    float hx = layerHeight(l, uv + float2(e, 0)) - layerHeight(l, uv - float2(e, 0));
    float hy = layerHeight(l, uv + float2(0, e)) - layerHeight(l, uv - float2(0, e));
    float bump = l == 1 ? 9.0 : (l == 3 ? 3.0 : 6.0);
    float2 slope = -float2(hx, hy) * bump;
    float3 c; float rough;
    if (l == 0) {
        float hue = tfbm(uv, 4, 4, 13);
        c = mix(float3(0.035, 0.062, 0.014), float3(0.085, 0.115, 0.028), hue) * (0.7 + 0.6 * h);
        float dry = smoothstep(0.55, 0.72, tfbm(uv, 3, 3, 14));
        c = mix(c, float3(0.14, 0.12, 0.055), dry * 0.6);
        rough = 0.82 + 0.15 * (1.0 - h);
    } else if (l == 1) {
        float tint = tfbm(uv, 6, 4, 25);
        c = mix(float3(0.16, 0.15, 0.14), float3(0.34, 0.31, 0.28), h) * mix(float3(1.0), float3(1.08, 1.0, 0.9), tint);
        float lichen = smoothstep(0.62, 0.75, tfbm(uv, 12, 3, 26)) * smoothstep(0.4, 0.7, h);
        c = mix(c, float3(0.20, 0.21, 0.12), lichen * 0.5);
        rough = 0.65 + 0.25 * (1.0 - h);
    } else if (l == 2) {
        float t2 = tfbm(uv, 6, 4, 33);
        c = mix(float3(0.25, 0.19, 0.12), float3(0.46, 0.39, 0.28), t2) * (0.75 + 0.45 * h);
        rough = 0.92;
    } else {
        c = float3(0.80, 0.83, 0.88) * (0.9 + 0.1 * h);
        rough = 0.42 + 0.25 * h;
    }
    float ao = mix(0.55, 1.0, saturate(h * 1.4));
    albedo.write(float4(c, rough), gid.xy, l);
    nh.write(float4(slope, h, ao), gid.xy, l);
}
"""#
}
