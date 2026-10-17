// Shared shader code (port of Sources/Render/ShaderCommon.swift): frame uniforms, binding conventions, atmosphere
// (Hillaire 2020-lite), aerial-perspective LUT, PBR (GGX / Smith / Schlick), cascaded shadows.
//
// Binding convention (pw/gpu.h):  b0..b3 constants | t0..t7 textures | t8..t11 structured float4 buffers |
// u8..u11 storage textures | s0 shadow compare, s1 linear clamp, s2 linear repeat-U, s3 point clamp.
// Slang maps the register numbers 1:1 to Metal buffer / texture / sampler indices.
//
// Coordinates on the GPU: camera-relative world space (float), +Y up, metres. Matrices are stored as four float4
// columns (struct Mat) and multiplied explicitly, so the memory layout is identical on every target.
#pragma once

struct Mat { float4 c0; float4 c1; float4 c2; float4 c3; };
float4 mulM(Mat m, float4 v) { return m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w; }
float3 mulM3(Mat m, float3 v) { return m.c0.xyz * v.x + m.c1.xyz * v.y + m.c2.xyz * v.z; }

struct FrameUniforms
{
    Mat viewProj;            // jittered (TAA)
    Mat viewProjNoJitter;
    Mat prevViewProj;        // previous frame, no jitter, re-based to the current camera origin
    Mat invViewProj;         // inverse of the jittered viewProj
    Mat view;
    Mat proj;
    Mat cascadeViewProj[4];
    float4 cascadeSplits;    // far distance of each cascade (view depth, m)
    float4 cameraWorld;      // xyz absolute camera position (approx), w camera altitude above sea level (m)
    float4 sunDir;           // xyz unit vector toward the sun, w sun illuminance scale
    float4 sunColor;         // rgb extraterrestrial sun colour, w sun angular radius (rad)
    float4 params;           // x time (s), y exposure, zw TAA jitter (NDC)
    float4 resolution;       // w, h, 1/w, 1/h
    float4 atmos;            // x aerial-perspective scale, y shadow distance, z frame index, w bloom strength
    float4 cameraForward;    // xyz forward, w near plane
    float4 wind;             // xyz wind velocity (m/s), w gust phase
    float4 quality;          // x 1 = fast analytic atmosphere, y fog extinction per km, z 1 = sRGB-encode output
    float4 fogColor;         // rgb fog colour (per unit sun illuminance) for the fast path
};

ConstantBuffer<FrameUniforms> gFrame : register(b0);

SamplerComparisonState gShadowCmp : register(s0);
SamplerState gLinearClamp : register(s1);
SamplerState gLinearRepeatU : register(s2);
SamplerState gPointClamp : register(s3);

static const float PI = 3.14159265358979;

// ---------------------------------------------------------------- atmosphere (units: km)
static const float Rg = 6360.0;
static const float Rt = 6460.0;
static const float3 kRayleighS = float3(5.802, 13.558, 33.1) * 1e-3;
static const float kMieS = 3.996e-3;
static const float kMieE = 4.40e-3;
static const float3 kOzoneA = float3(0.650, 1.881, 0.085) * 1e-3;

struct Medium { float3 scatR; float scatM; float3 ext; };

Medium sampleMedium(float h)
{
    h = max(h, 0.0);
    float dR = exp(-h / 8.0), dM = exp(-h / 1.2), dO = max(0.0, 1.0 - abs(h - 25.0) / 15.0);
    Medium m;
    m.scatR = kRayleighS * dR; m.scatM = kMieS * dM; m.ext = m.scatR + kMieE * dM + kOzoneA * dO;
    return m;
}
float raySphereFar(float3 ro, float3 rd, float r)
{
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return -1.0;
    return -b + sqrt(d);
}
float raySphereNear(float3 ro, float3 rd, float r)
{
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return -1.0;
    float t = -b - sqrt(d);
    return t > 0.0 ? t : -1.0;
}
float rayleighPhase(float mu) { return 3.0 / (16.0 * PI) * (1.0 + mu * mu); }
float miePhase(float mu)
{
    const float g = 0.8; float g2 = g * g;
    return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}
// Fast path: Kasten-Young air mass through an exponential atmosphere (no ray march).
float3 fastSunTransmittance(float3 sunDir)
{
    float mu = clamp(sunDir.y, -0.1, 1.0);
    float elevDeg = asin(max(mu, 0.0)) * 57.2958;
    float air = 1.0 / (max(mu, 0.0) + 0.15 * pow(max(93.885 - elevDeg, 0.1), -1.253));
    float3 od = (float3(5.802, 13.558, 33.1) * 1e-3 * 8.0 + 4.40e-3 * 1.2 + float3(0.650, 1.881, 0.085) * 1e-3 * 0.8) * air;
    return exp(-od) * smoothstep(-0.03, 0.02, sunDir.y);
}
// Transmittance from point p (km, planet-centred) toward the sun; soft horizon via the ground test.
float3 transmittanceToSun(float3 p, float3 sunDir)
{
    float r = length(p);
    float muH = -sqrt(max(0.0, 1.0 - (Rg * Rg) / (r * r)));
    float mu = dot(p / r, sunDir);
    float vis = smoothstep(muH - 0.01, muH + 0.01, mu);
    if (vis <= 0.0) return float3(0.0, 0.0, 0.0);
    float tMax = raySphereFar(p, sunDir, Rt);
    float dt = tMax / 8.0;
    float3 od = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < 8; i++)
    {
        float3 q = p + sunDir * ((float(i) + 0.5) * dt);
        od += sampleMedium(length(q) - Rg).ext * dt;
    }
    return exp(-od) * vis;
}
// Single scattering + a cheap isotropic multiple-scattering term along a ray segment.
// Returns in-scattered radiance per unit sun illuminance; T receives the segment transmittance.
float3 integrateScattering(float3 ro, float3 rd, float tMax, float3 sunDir, int steps, out float3 T)
{
    float mu = dot(rd, sunDir);
    float pR = rayleighPhase(mu), pM = miePhase(mu);
    float3 L = float3(0.0, 0.0, 0.0);
    T = float3(1.0, 1.0, 1.0);
    float dt = tMax / float(steps);
    for (int i = 0; i < steps; i++)
    {
        float3 p = ro + rd * ((float(i) + 0.5) * dt);
        float h = length(p) - Rg;
        Medium m = sampleMedium(h);
        float3 sunT = transmittanceToSun(p, sunDir);
        float3 scat = m.scatR + m.scatM;
        float3 S = (m.scatR * pR + m.scatM * pM) * sunT + scat * (0.25 / PI) * 0.6 * (sunT * 0.5 + 0.08);
        float3 stepT = exp(-m.ext * dt);
        L += T * (S - S * stepT) / max(m.ext, float3(1e-7, 1e-7, 1e-7));
        T *= stepT;
    }
    return L;
}
float3 planetPos(float3 relPosMeters)
{
    return float3(0.0, Rg + max(gFrame.cameraWorld.w, 1.0) * 1e-3, 0.0) + relPosMeters * 1e-3;
}
// Sky-view LUT parameterisation: u = azimuth / 2pi, v = 0.5 + 0.5 sign(e) sqrt(|e| / (pi/2)).
float2 skyLUTUV(float3 dir)
{
    float az = atan2(dir.z, dir.x);
    if (az < 0.0) az += 2.0 * PI;
    float el = asin(clamp(dir.y, -1.0, 1.0));
    float v = 0.5 + 0.5 * sign(el) * sqrt(abs(el) / (0.5 * PI));
    return float2(az / (2.0 * PI), v);
}
float3 skyLUTDir(float2 uv)
{
    float az = uv.x * 2.0 * PI;
    float l = uv.y * 2.0 - 1.0;
    float el = sign(l) * l * l * 0.5 * PI;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}
float3 sampleSky(Texture2D<float4> lut, float3 dir)
{
    return lut.SampleLevel(gLinearRepeatU, skyLUTUV(normalize(dir)), 0.0).rgb;
}
// Aerial perspective for a surface at camera-relative position rel (m): inscatter, T = transmittance.
float3 aerialPerspective(float3 rel, out float3 T)
{
    float dist = length(rel);
    float3 rd = rel / max(dist, 1e-3);
    float3 ro = planetPos(float3(0.0, 0.0, 0.0));
    float3 L = integrateScattering(ro, rd, dist * 1e-3 * gFrame.atmos.x, gFrame.sunDir.xyz, 6, T);
    return L * gFrame.sunColor.rgb * gFrame.sunDir.w;
}

// ---------------------------------------------------------------- PBR (GGX / Smith / Schlick)
float D_GGX(float NoH, float a) { float a2 = a * a; float d = NoH * NoH * (a2 - 1.0) + 1.0; return a2 / (PI * d * d); }
float V_SmithGGXCorrelated(float NoV, float NoL, float a)
{
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);
}
float3 F_Schlick(float3 f0, float VoH) { return f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0); }
// Karis' analytic approximation of the split-sum environment BRDF.
float2 envBRDFApprox(float roughness, float NoV)
{
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

// ---------------------------------------------------------------- cascaded shadows
float shadowCascadeSplit(int c)
{
    return c == 0 ? gFrame.cascadeSplits.x : c == 1 ? gFrame.cascadeSplits.y : c == 2 ? gFrame.cascadeSplits.z : gFrame.cascadeSplits.w;
}
float sampleShadow(DepthTexture2DArray sm, float3 rel, float3 n, float viewDepth)
{
    int c = 0;
    if (viewDepth > gFrame.cascadeSplits.x) c = 1;
    if (viewDepth > gFrame.cascadeSplits.y) c = 2;
    if (viewDepth > gFrame.cascadeSplits.z) c = 3;
    if (viewDepth > gFrame.cascadeSplits.w) return 1.0;
    uint smW, smH, smL;
    sm.GetDimensions(smW, smH, smL);
    float texel = 2.0 * shadowCascadeSplit(c) / float(smW);
    float3 p = rel + n * texel * 1.5;                                 // normal-offset bias
    float4 lc = mulM(gFrame.cascadeViewProj[c], float4(p, 1.0));
    float3 uvz = lc.xyz / lc.w;
    float2 uv = uvz.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float d = uvz.z - 0.0005;
    float2 ts = 1.0 / float2(float(smW), float(smH));
    float layer = float(c);
    // 3x3 hardware PCF covers a 4x4 texel footprint; the four corner taps cover the same 16 texels, so when they
    // agree (fully lit or fully shadowed) the remaining five taps cannot change the result.
    float corners = sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(-1, -1) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(1, -1) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(-1, 1) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(1, 1) * ts, layer), d);
    float s;
    if (corners == 0.0 || corners == 4.0) s = corners * 0.25;
    else
    {
        float sum = corners + sm.SampleCmpLevelZero(gShadowCmp, float3(uv, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(0, -1) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(0, 1) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(-1, 0) * ts, layer), d)
                  + sm.SampleCmpLevelZero(gShadowCmp, float3(uv + float2(1, 0) * ts, layer), d);
        s = sum / 9.0;
    }
    float fade = smoothstep(gFrame.cascadeSplits.w * 0.85, gFrame.cascadeSplits.w, viewDepth);
    return lerp(s, 1.0, fade);
}

// Full surface shading used by the standard mesh pipeline and by modules (terrain, vegetation, water).
float3 shadeSurfaceT(Texture2D<float4> skyLUT, DepthTexture2DArray shadowMap, float3 rel, float3 N, float3 albedo,
                     float roughness, float metallic, float ao, float3 sunT)
{
    float3 V = normalize(-rel);
    float3 Ls = gFrame.sunDir.xyz;
    float NoV = max(dot(N, V), 1e-4), NoL = saturate(dot(N, Ls));
    float a = max(roughness * roughness, 0.002);
    float3 f0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);
    float3 diffuseColor = albedo * (1.0 - metallic);

    float viewDepth = dot(rel, gFrame.cameraForward.xyz);
    float shadow = NoL > 0.0 ? sampleShadow(shadowMap, rel, N, viewDepth) : 0.0;
    float3 sunE = gFrame.sunColor.rgb * gFrame.sunDir.w * sunT;

    float3 H = normalize(V + Ls);
    float NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
    float3 F = F_Schlick(f0, VoH);
    float3 spec = D_GGX(NoH, a) * V_SmithGGXCorrelated(NoV, NoL, a) * F;
    float3 direct = (diffuseColor * (1.0 - F) / PI + spec) * sunE * NoL * shadow;

    // Image-based lighting from the sky-view LUT (diffuse ~ pi L(n'), specular from the reflected direction).
    float3 skyScale = gFrame.sunColor.rgb * gFrame.sunDir.w;
    float3 nUp = normalize(N + float3(0, 0.6, 0));
    float3 irradiance = sampleSky(skyLUT, nUp) * skyScale * PI * 0.5 * saturate(0.5 + 0.5 * N.y)
                      + sunE * 0.12 * saturate(-N.y * 0.5 + 0.5) * 0.3;      // crude ground bounce
    float3 R = reflect(-V, N);
    R.y = max(R.y, 0.02);
    float3 prefiltered = lerp(sampleSky(skyLUT, R), sampleSky(skyLUT, nUp), saturate(roughness * 1.2)) * skyScale;
    float2 ab = envBRDFApprox(roughness, NoV);
    float3 ambient = (diffuseColor * irradiance / PI + prefiltered * (f0 * ab.x + ab.y)) * ao;
    return direct + ambient;
}

// ---------------------------------------------------------------- aerial-perspective LUT
// Per-frame 3D LUT over (view azimuth, view elevation, distance) holding exactly what aerialPerspective() and
// transmittanceToSun(planetPos(rel)) return, so surfaces pay three trilinear fetches instead of ~56 medium evaluations.
static const float kAerialMaxDist = 100000.0;     // m; beyond this the exact integration is used
static const int kAerialW = 64;
static const int kAerialH = 64;
static const int kAerialD = 48;
float aerialUnit(float x, int n) { return 0.5 / float(n) + x * (1.0 - 1.0 / float(n)); }
float2 aerialUV(float3 dir)
{
    float az = atan2(dir.z, dir.x) * (0.5 / PI);
    float el = asin(clamp(dir.y, -1.0, 1.0));
    float v = 0.5 + 0.5 * sign(el) * sqrt(abs(el) / (0.5 * PI));
    return float2(az, aerialUnit(v, kAerialH));
}
float aerialW(float dist) { return aerialUnit(sqrt(saturate(dist / kAerialMaxDist)), kAerialD); }
float3 aerialDirFromUV(float u, float v)
{
    float az = u * 2.0 * PI;
    float l = v * 2.0 - 1.0;
    float el = sign(l) * l * l * 0.5 * PI;
    return float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
}
struct AerialSample { float3 L; float3 T; float3 sunT; };
AerialSample aerialLookup(Texture3D<float4> apL, Texture3D<float4> apT, Texture3D<float4> apS, float3 rel)
{
    AerialSample a;
    float dist = length(rel);
    if (gFrame.quality.x > 0.5)
    {
        float T = exp(-dist * 1e-3 * gFrame.quality.y);
        a.L = gFrame.fogColor.rgb * gFrame.sunDir.w * (1.0 - T); a.T = float3(T, T, T); a.sunT = fastSunTransmittance(gFrame.sunDir.xyz);
        return a;
    }
    float3 dir = rel / max(dist, 1e-3);
    if (dist * gFrame.atmos.x > kAerialMaxDist)                       // rare: exact path
    {
        a.L = aerialPerspective(rel, a.T);
        a.sunT = transmittanceToSun(planetPos(rel), gFrame.sunDir.xyz);
        return a;
    }
    float2 uv = aerialUV(dir);
    float3 uvw = float3(uv, aerialW(dist * gFrame.atmos.x));
    a.L = apL.SampleLevel(gLinearRepeatU, uvw, 0.0).rgb;
    a.T = apT.SampleLevel(gLinearRepeatU, uvw, 0.0).rgb;
    // sun transmittance depends on the true point (not the scaled aerial distance)
    a.sunT = apS.SampleLevel(gLinearRepeatU, float3(uv, aerialW(dist)), 0.0).rgb;
    return a;
}

float3 applyAerial(float3 color, float3 rel)
{
    if (gFrame.quality.x > 0.5)
    {
        float T = exp(-length(rel) * 1e-3 * gFrame.quality.y);
        return color * T + gFrame.fogColor.rgb * gFrame.sunDir.w * (1.0 - T);
    }
    float3 T;
    float3 L = aerialPerspective(rel, T);
    return color * T + L;
}

// Fullscreen triangle.
struct FSOut { float4 position : SV_Position; float2 uv : TEXCOORD0; };
FSOut fullscreenTriangle(uint vid)
{
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
