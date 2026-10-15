// Germ War MSL (compiled at runtime with ShaderCommon.header prepended).
enum GermShaders {
    static let source = #"""
// ---------------------------------------------------------------- terrain
struct GWTerrainOut { float4 position [[position]]; float3 rel; float3 normal; float3 world; };

vertex GWTerrainOut gwTerrainVertex(uint vid [[vertex_id]], const device MeshVertex *verts [[buffer(0)]],
                                    constant float4 &origin [[buffer(1)]], constant FrameUniforms &f [[buffer(2)]]) {
    MeshVertex v = verts[vid];
    float3 w = float3(v.position);
    GWTerrainOut o;
    o.rel = w - origin.xyz;
    o.position = f.viewProj * float4(o.rel, 1.0);
    o.normal = float3(v.normal); o.world = w;
    return o;
}

inline float gwHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
inline float gwNoise(float2 p) {
    float2 i = floor(p), u = fract(p); u = u * u * (3.0 - 2.0 * u);
    return mix(mix(gwHash(i), gwHash(i + float2(1, 0)), u.x), mix(gwHash(i + float2(0, 1)), gwHash(i + float2(1, 1)), u.x), u.y);
}

fragment float4 gwTerrainFragment(GWTerrainOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]],
                                  depth2d_array<float> shadowMap [[texture(0)]], texture2d<float> skyLUT [[texture(1)]]) {
    float h = in.world.y, r = length(in.world.xz);
    float3 lo = float3(0.010, 0.045, 0.075), mid = float3(0.03, 0.16, 0.12), hi = float3(0.32, 0.06, 0.20),
           peak = float3(0.62, 0.30, 0.25), rim = float3(0.55, 0.45, 0.28), pad = float3(0.05, 0.075, 0.10);
    float3 c = mix(lo, mid, smoothstep(-25.0, 2.0, h));
    c = mix(c, hi, smoothstep(8.0, 30.0, h));
    c = mix(c, peak, smoothstep(30.0, 45.0, h) * 0.6);
    c = mix(c, pad, (1.0 - smoothstep(280.0, 430.0, r)) * 0.8);
    c = mix(c, rim, smoothstep(1880.0, 2150.0, r));
    float n = gwNoise(in.world.xz * 0.05) * 0.6 + gwNoise(in.world.xz * 0.21) * 0.4;
    c *= 0.82 + 0.36 * n;
    // bioluminescent veins outside the base
    float vein = abs(sin(in.world.x * 0.02 + sin(in.world.z * 0.013) * 3.0));
    float veinMask = (1.0 - smoothstep(0.0, 0.05, vein)) * smoothstep(430.0, 520.0, r) * (1.0 - smoothstep(1850.0, 1950.0, r));
    float3 N = normalize(in.normal);
    float3 col = shadeSurface(f, skyLUT, shadowMap, in.rel, N, c, 0.9, 0.0, 1.0);
    col += float3(0.15, 1.0, 0.75) * veinMask * (0.6 + 0.4 * sin(f.params.x * 1.5 + in.world.x * 0.01));
    col = applyAerial(f, col, in.rel);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- effects (glow / translucent)
struct FXInstance { float4x4 model; float4 color; float4 params; };   // params.x rim, params.y mode (1 = water)
struct GWFXOut { float4 position [[position]]; float3 rel; float3 normal; float4 color [[flat]]; float4 params [[flat]]; };

vertex GWFXOut gwFXVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device MeshVertex *verts [[buffer(0)]],
                          const device FXInstance *inst [[buffer(1)]], constant FrameUniforms &f [[buffer(2)]]) {
    MeshVertex v = verts[vid]; FXInstance I = inst[iid];
    float4 wp = I.model * float4(float3(v.position), 1.0);
    GWFXOut o;
    o.position = f.viewProj * wp; o.rel = wp.xyz;
    float3x3 nm = float3x3(I.model[0].xyz, I.model[1].xyz, I.model[2].xyz);
    o.normal = normalize(nm * float3(v.normal));
    o.color = I.color; o.params = I.params;
    return o;
}

fragment float4 gwFXFragment(GWFXOut in [[stage_in]], constant FrameUniforms &f [[buffer(2)]],
                             depth2d_array<float> shadowMap [[texture(0)]], texture2d<float> skyLUT [[texture(1)]]) {
    float3 N = normalize(in.normal), V = normalize(-in.rel);
    float ndv = abs(dot(N, V));
    if (in.params.y > 0.5) {           // water: fresnel sky reflection + sun glint over a deep tint
        float3 n = float3(0, 1, 0);
        float2 w = in.rel.xz + f.cameraWorld.xz;
        n.xz += float2(sin(w.x * 0.05 + f.params.x * 0.9), cos(w.y * 0.045 + f.params.x * 0.7)) * 0.04;
        n = normalize(n);
        float fr = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, V)), 5.0);
        float3 R = reflect(-V, n);
        float3 sky = sampleSky(skyLUT, R);
        float3 sunR = pow(saturate(dot(R, f.sunDir.xyz)), 400.0) * f.sunDir.w * float3(1.0, 0.95, 0.85) * 2.0;
        float3 c = mix(in.color.rgb * f.sunDir.w * 0.08, sky, fr) + sunR;
        c = applyAerial(f, c, in.rel);
        return float4(c, mix(in.color.a, 1.0, fr));
    }
    float rim = pow(1.0 - ndv, 2.0);
    float a = in.color.a * mix(1.0, rim * 1.6 + 0.12, in.params.x);
    return float4(in.color.rgb * (1.0 + rim * in.params.x), saturate(a));
}
"""#
}
