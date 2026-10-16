// Shared Metal shader header, prepended to every runtime-compiled library (no offline `metal` tool).
// Modules writing their own shaders: `try ShaderLibrary.shared.library(named: "water", source: myMSL)` —
// the header below is prepended automatically, so FrameUniforms, atmosphere and PBR helpers are available.
//
// Coordinate convention on the GPU: camera-relative world space (float), +Y up, units metres.
// `frame.cameraWorld.xyz` holds the absolute camera position (float, for procedural patterns only).

public enum ShaderCommon {
    public static let header = #"""
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;           // jittered (TAA)
    float4x4 viewProjNoJitter;
    float4x4 prevViewProj;       // previous frame, no jitter, re-based to current camera origin
    float4x4 invViewProj;        // inverse of jittered viewProj
    float4x4 view;
    float4x4 proj;
    float4x4 cascadeViewProj[4];
    float4 cascadeSplits;        // far distance of each cascade (view depth, m)
    float4 cameraWorld;          // xyz absolute camera pos (approx), w = camera altitude above sea level (m)
    float4 sunDir;               // xyz unit vector toward sun, w = sun illuminance scale
    float4 sunColor;             // rgb extraterrestrial sun colour, w = sun angular radius (rad)
    float4 params;               // x time (s), y exposure, zw TAA jitter (NDC)
    float4 resolution;           // w, h, 1/w, 1/h
    float4 atmos;                // x aerial-perspective scale, y shadow distance, z frame index, w bloom strength
    float4 cameraForward;        // xyz forward, w = near plane
    float4 wind;                 // xyz wind velocity (m/s), w = gust phase
    float4 quality;              // x 1 = fast analytic atmosphere, y fog extinction per km
    float4 fogColor;             // rgb fog colour (per unit sun illuminance) for the fast path
};

// Per-instance data for the standard PBR mesh pipeline (80 bytes).
struct MeshInstance {
    float4x4 model;              // camera-relative model matrix
    float4 color;                // rgb linear albedo, a = roughness
    float4 material;             // x metallic, y emissive strength, z pattern id (0 none,1 ground grid), w alpha/unused
};

struct MeshVertex { packed_float3 position; packed_float3 normal; float2 uv; };

constant float PI = 3.14159265358979;

// ---------------------------------------------------------------- atmosphere (Hillaire 2020-lite)
// Units: km. Planet centre is below the camera at (0, -(Rg + altitude), 0) in camera-relative space.
constant float Rg = 6360.0;
constant float Rt = 6460.0;
constant float3 kRayleighS = float3(5.802, 13.558, 33.1) * 1e-3;
constant float  kMieS = 3.996e-3;
constant float  kMieE = 4.40e-3;
constant float3 kOzoneA = float3(0.650, 1.881, 0.085) * 1e-3;

struct Medium { float3 scatR; float scatM; float3 ext; };

inline Medium sampleMedium(float h) {
    h = max(h, 0.0);
    float dR = exp(-h / 8.0), dM = exp(-h / 1.2), dO = max(0.0, 1.0 - abs(h - 25.0) / 15.0);
    Medium m; m.scatR = kRayleighS * dR; m.scatM = kMieS * dM; m.ext = m.scatR + kMieE * dM + kOzoneA * dO; return m;
}
inline float raySphereFar(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return -1.0;
    return -b + sqrt(d);
}
inline float raySphereNear(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return -1.0;
    float t = -b - sqrt(d);
    return t > 0.0 ? t : -1.0;
}
inline float rayleighPhase(float mu) { return 3.0 / (16.0 * PI) * (1.0 + mu * mu); }
inline float miePhase(float mu) {
    const float g = 0.8; float g2 = g * g;
    return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}
// Transmittance from point p (km, planet-centred) toward the sun. Soft horizon via ground test.
// Fast path: Kasten–Young air mass through an exponential atmosphere (no ray-march).
inline float3 fastSunTransmittance(float3 sunDir) {
    float mu = clamp(sunDir.y, -0.1, 1.0);
    float elevDeg = asin(max(mu, 0.0)) * 57.2958;
    float air = 1.0 / (max(mu, 0.0) + 0.15 * pow(max(93.885 - elevDeg, 0.1), -1.253));
    float3 od = (float3(5.802, 13.558, 33.1) * 1e-3 * 8.0 + 4.40e-3 * 1.2 + float3(0.650, 1.881, 0.085) * 1e-3 * 0.8) * air;
    return exp(-od) * smoothstep(-0.03, 0.02, sunDir.y);
}
inline float3 transmittanceToSun(float3 p, float3 sunDir) {
    float r = length(p);
    float muH = -sqrt(max(0.0, 1.0 - (Rg * Rg) / (r * r)));      // cos of horizon angle
    float mu = dot(p / r, sunDir);
    float vis = smoothstep(muH - 0.01, muH + 0.01, mu);
    if (vis <= 0.0) return float3(0.0);
    float tMax = raySphereFar(p, sunDir, Rt);
    float dt = tMax / 8.0; float3 od = 0.0;
    for (int i = 0; i < 8; i++) {
        float3 q = p + sunDir * ((float(i) + 0.5) * dt);
        od += sampleMedium(length(q) - Rg).ext * dt;
    }
    return exp(-od) * vis;
}
// Single scattering + cheap isotropic multiple-scattering term along a ray segment.
// Returns in-scattered radiance per unit sun illuminance; T receives segment transmittance.
inline float3 integrateScattering(float3 ro, float3 rd, float tMax, float3 sunDir, int steps, thread float3 &T) {
    float mu = dot(rd, sunDir);
    float pR = rayleighPhase(mu), pM = miePhase(mu);
    float3 L = 0.0; T = 1.0;
    float dt = tMax / float(steps);
    for (int i = 0; i < steps; i++) {
        float3 p = ro + rd * ((float(i) + 0.5) * dt);
        float h = length(p) - Rg;
        Medium m = sampleMedium(h);
        float3 sunT = transmittanceToSun(p, sunDir);
        float3 scat = m.scatR + m.scatM;
        float3 S = (m.scatR * pR + m.scatM * pM) * sunT
                 + scat * (0.25 / PI) * 0.6 * (sunT * 0.5 + 0.08);       // multiple scattering approximation
        float3 stepT = exp(-m.ext * dt);
        L += T * (S - S * stepT) / max(m.ext, float3(1e-7));
        T *= stepT;
    }
    return L;
}
inline float3 planetPos(constant FrameUniforms &f, float3 relPosMeters) {
    return float3(0.0, Rg + max(f.cameraWorld.w, 1.0) * 1e-3, 0.0) + relPosMeters * 1e-3;
}
// Sky-view LUT parameterisation: u = azimuth/(2π), v = 0.5 + 0.5*sign(e)*sqrt(|e|/(π/2)).
inline float2 skyLUTUV(float3 dir) {
    float az = atan2(dir.z, dir.x); if (az < 0.0) az += 2.0 * PI;
    float el = asin(clamp(dir.y, -1.0, 1.0));
    float v = 0.5 + 0.5 * sign(el) * sqrt(abs(el) / (0.5 * PI));
    return float2(az / (2.0 * PI), v);
}
inline float3 skyLUTDir(float2 uv) {
    float az = uv.x * 2.0 * PI;
    float l = uv.y * 2.0 - 1.0;
    float el = sign(l) * l * l * 0.5 * PI;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}
inline float3 sampleSky(texture2d<float> lut, float3 dir) {
    constexpr sampler s(filter::linear, address::repeat);
    return lut.sample(s, skyLUTUV(normalize(dir))).rgb;
}
// Aerial perspective for a surface at camera-relative position `rel` (m). Returns (inscatter, transmittance).
inline float3 aerialPerspective(constant FrameUniforms &f, float3 rel, thread float3 &T) {
    float dist = length(rel);
    float3 rd = rel / max(dist, 1e-3);
    float3 ro = planetPos(f, float3(0.0));
    float3 L = integrateScattering(ro, rd, dist * 1e-3 * f.atmos.x, f.sunDir.xyz, 6, T);
    return L * f.sunColor.rgb * f.sunDir.w;
}

// ---------------------------------------------------------------- PBR (GGX / Smith / Schlick)
inline float D_GGX(float NoH, float a) { float a2 = a * a; float d = NoH * NoH * (a2 - 1.0) + 1.0; return a2 / (PI * d * d); }
inline float V_SmithGGXCorrelated(float NoV, float NoL, float a) {
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);
}
inline float3 F_Schlick(float3 f0, float VoH) { return f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0); }
// Karis' analytic approximation of the split-sum environment BRDF.
inline float2 envBRDFApprox(float roughness, float NoV) {
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

// ---------------------------------------------------------------- cascaded shadows
inline float sampleShadow(constant FrameUniforms &f, depth2d_array<float> sm, float3 rel, float3 n, float viewDepth) {
    constexpr sampler cmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    int c = 0;
    if (viewDepth > f.cascadeSplits.x) c = 1;
    if (viewDepth > f.cascadeSplits.y) c = 2;
    if (viewDepth > f.cascadeSplits.z) c = 3;
    if (viewDepth > f.cascadeSplits.w) return 1.0;
    float texel = 2.0 * f.cascadeSplits[c] / float(sm.get_width()) ;
    float3 p = rel + n * texel * 1.5;                            // normal-offset bias
    float4 lc = f.cascadeViewProj[c] * float4(p, 1.0);
    float3 uvz = lc.xyz / lc.w;
    float2 uv = uvz.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float d = uvz.z - 0.0005;
    float2 ts = 1.0 / float2(sm.get_width(), sm.get_height());
    // 3x3 hardware-PCF taps cover a 4x4 texel footprint; the four corner taps alone cover the same 16 texels,
    // so when they agree (fully lit or fully shadowed) the remaining five taps cannot change the result.
    float corners = sm.sample_compare(cmp, uv + float2(-1, -1) * ts, c, d) + sm.sample_compare(cmp, uv + float2(1, -1) * ts, c, d)
                  + sm.sample_compare(cmp, uv + float2(-1, 1) * ts, c, d) + sm.sample_compare(cmp, uv + float2(1, 1) * ts, c, d);
    float s;
    if (corners == 0.0 || corners == 4.0) s = corners * 0.25;
    else {
        float sum = corners + sm.sample_compare(cmp, uv, c, d)
                  + sm.sample_compare(cmp, uv + float2(0, -1) * ts, c, d) + sm.sample_compare(cmp, uv + float2(0, 1) * ts, c, d)
                  + sm.sample_compare(cmp, uv + float2(-1, 0) * ts, c, d) + sm.sample_compare(cmp, uv + float2(1, 0) * ts, c, d);
        s = sum / 9.0;
    }
    float fade = smoothstep(f.cascadeSplits.w * 0.85, f.cascadeSplits.w, viewDepth);
    return mix(s, 1.0, fade);
}

// Full surface shading used by the standard mesh pipeline and by modules (terrain, vegetation, water).
inline float3 shadeSurfaceT(constant FrameUniforms &f, texture2d<float> skyLUT, depth2d_array<float> shadowMap,
                            float3 rel, float3 N, float3 albedo, float roughness, float metallic, float ao, float3 sunT);
inline float3 shadeSurface(constant FrameUniforms &f, texture2d<float> skyLUT, depth2d_array<float> shadowMap,
                           float3 rel, float3 N, float3 albedo, float roughness, float metallic, float ao) {
    float3 sunT = f.quality.x > 0.5 ? fastSunTransmittance(f.sunDir.xyz) : transmittanceToSun(planetPos(f, rel), f.sunDir.xyz);
    return shadeSurfaceT(f, skyLUT, shadowMap, rel, N, albedo, roughness, metallic, ao, sunT);
}
inline float3 shadeSurfaceT(constant FrameUniforms &f, texture2d<float> skyLUT, depth2d_array<float> shadowMap,
                            float3 rel, float3 N, float3 albedo, float roughness, float metallic, float ao, float3 sunT) {
    float3 V = normalize(-rel);
    float3 Ls = f.sunDir.xyz;
    float NoV = max(dot(N, V), 1e-4), NoL = saturate(dot(N, Ls));
    float a = max(roughness * roughness, 0.002);
    float3 f0 = mix(float3(0.04), albedo, metallic);
    float3 diffuseColor = albedo * (1.0 - metallic);

    float viewDepth = dot(rel, f.cameraForward.xyz);
    float shadow = NoL > 0.0 ? sampleShadow(f, shadowMap, rel, N, viewDepth) : 0.0;
    float3 sunE = f.sunColor.rgb * f.sunDir.w * sunT;

    float3 H = normalize(V + Ls);
    float NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
    float3 F = F_Schlick(f0, VoH);
    float3 spec = D_GGX(NoH, a) * V_SmithGGXCorrelated(NoV, NoL, a) * F;
    float3 direct = (diffuseColor * (1.0 - F) / PI + spec) * sunE * NoL * shadow;

    // Image-based lighting from the sky-view LUT (diffuse ≈ π·L(n'), specular from reflected direction).
    float3 skyScale = f.sunColor.rgb * f.sunDir.w;
    float3 nUp = normalize(N + float3(0, 0.6, 0));
    float3 irradiance = sampleSky(skyLUT, nUp) * skyScale * PI * 0.5 * saturate(0.5 + 0.5 * N.y)
                      + sunE * 0.12 * saturate(-N.y * 0.5 + 0.5) * 0.3;     // crude ground bounce
    float3 R = reflect(-V, N);
    R.y = max(R.y, 0.02);
    float3 prefiltered = mix(sampleSky(skyLUT, R), sampleSky(skyLUT, nUp), saturate(roughness * 1.2)) * skyScale;
    float2 ab = envBRDFApprox(roughness, NoV);
    float3 ambient = (diffuseColor * irradiance / PI + prefiltered * (f0 * ab.x + ab.y)) * ao;
    return direct + ambient;
}

// ---------------------------------------------------------------- aerial-perspective LUT
// Per-frame 3D LUT over (view azimuth, view elevation, distance) holding exactly what aerialPerspective() and
// transmittanceToSun(planetPos(rel)) return, so surfaces pay three trilinear fetches instead of ~56 medium evaluations.
// Bound by FrameContext.bindFrame at fragment textures 13 (inscatter), 14 (view transmittance), 15 (sun transmittance).
constant float kAerialMaxDist = 100000.0;      // m; beyond this the exact integration is used
constant int kAerialW = 64, kAerialH = 64, kAerialD = 48;
inline float aerialUnit(float x, int n) { return 0.5 / float(n) + x * (1.0 - 1.0 / float(n)); }
inline float2 aerialUV(float3 dir) {
    float az = atan2(dir.z, dir.x) * (0.5 / PI);
    float el = asin(clamp(dir.y, -1.0, 1.0));
    float v = 0.5 + 0.5 * sign(el) * sqrt(abs(el) / (0.5 * PI));
    return float2(az, aerialUnit(v, kAerialH));
}
inline float aerialW(float dist) { return aerialUnit(sqrt(saturate(dist / kAerialMaxDist)), kAerialD); }
inline float3 aerialDirFromUV(float u, float v) {
    float az = u * 2.0 * PI;
    float l = v * 2.0 - 1.0;
    float el = sign(l) * l * l * 0.5 * PI;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}
struct AerialSample { float3 L; float3 T; float3 sunT; };
inline AerialSample aerialLookup(constant FrameUniforms &f, texture3d<float> apL, texture3d<float> apT, texture3d<float> apS, float3 rel) {
    AerialSample a;
    float dist = length(rel);
    if (f.quality.x > 0.5) {
        float T = exp(-dist * 1e-3 * f.quality.y);
        a.L = f.fogColor.rgb * f.sunDir.w * (1.0 - T); a.T = float3(T); a.sunT = fastSunTransmittance(f.sunDir.xyz);
        return a;
    }
    float3 dir = rel / max(dist, 1e-3);
    if (dist * f.atmos.x > kAerialMaxDist) {                     // rare: exact path
        a.L = aerialPerspective(f, rel, a.T);
        a.sunT = transmittanceToSun(planetPos(f, rel), f.sunDir.xyz);
        return a;
    }
    constexpr sampler s(filter::linear, s_address::repeat, t_address::clamp_to_edge, r_address::clamp_to_edge);
    float2 uv = aerialUV(dir);
    float3 uvw = float3(uv, aerialW(dist * f.atmos.x));
    a.L = apL.sample(s, uvw).rgb; a.T = apT.sample(s, uvw).rgb;
    // sun transmittance depends on the true point (not the scaled aerial distance)
    a.sunT = apS.sample(s, float3(uv, aerialW(dist))).rgb;
    return a;
}

inline float3 applyAerial(constant FrameUniforms &f, float3 color, float3 rel) {
    if (f.quality.x > 0.5) {
        float T = exp(-length(rel) * 1e-3 * f.quality.y);
        return color * T + f.fogColor.rgb * f.sunDir.w * (1.0 - T);
    }
    float3 T; float3 L = aerialPerspective(f, rel, T);
    return color * T + L;
}
"""#
}
