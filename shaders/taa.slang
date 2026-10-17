// Tiled TAA resolve (YCoCg neighbourhood clamp). One file per binding set: Slang's Metal output declares every
// global (and group-shared array) in each entry point.
#include "common.slang"

Texture2D<float4> gCurrent : register(t0);
Texture2D<float4> gHistory : register(t1);
DepthTexture2D gDepth : register(t2);
RWTexture2D<float4> gOut : register(u8);

struct PostParams { uint flag; float radius; uint pad0; uint pad1; };
ConstantBuffer<PostParams> gPost : register(b1);

// ============================================================ TAA resolve
float3 rgb2ycocg(float3 c) { return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25))); }
float3 ycocg2rgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }
float3 tmap(float3 c) { return c / (1.0 + max(c.r, max(c.g, c.b))); }
float3 tunmap(float3 c) { return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4); }

// Threadgroup-tiled: each TSxTS group loads its (TS+2)^2 neighbourhood (colour converted to tonemapped YCoCg once
// per texel, plus depth) into group-shared memory, then every pixel reads its 3x3 from there. The tile size comes
// from the per-vendor tuning table (taaResolve16 / taaResolve8). Dispatched as whole groups.
void taaResolvePixel(int2 gidI, int2 tidI, int TB, float3 cur, float3 m1, float3 m2, float closest, int2 cOff, int w, int h)
{
    float3 mean = m1 / 9.0, sd = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
    float2 uv = (float2(gidI) + 0.5) / float2(float(w), float(h));
    float2 uvC = (float2(gidI + cOff) + 0.5) / float2(float(w), float(h));
    float2 ndc = float2(uvC.x * 2.0 - 1.0, 1.0 - uvC.y * 2.0);
    float4 rel = mulM(gFrame.invViewProj, float4(ndc, max(closest, 1e-7), 1.0));
    rel /= rel.w;
    float4 prev = mulM(gFrame.prevViewProj, float4(rel.xyz, 1.0));
    float2 prevUV = float2(prev.x / prev.w * 0.5 + 0.5, 0.5 - prev.y / prev.w * 0.5);
    float2 velocity = prevUV - uvC;
    float2 hUV = uv + velocity;
    float3 result;
    if (gPost.flag != 0 || any(hUV < 0.0) || any(hUV > 1.0))
    {
        result = ycocg2rgb(cur);
    }
    else
    {
        float3 hist = rgb2ycocg(tmap(gHistory.SampleLevel(gLinearClamp, hUV, 0.0).rgb));
        float3 lo = mean - sd * 1.25, hi = mean + sd * 1.25;
        hist = clamp(hist, lo, hi);
        float speed = length(velocity * float2(float(w), float(h)));
        float alpha = lerp(0.08, 0.25, saturate(speed / 8.0));
        result = ycocg2rgb(lerp(hist, cur, alpha));
    }
    gOut[uint2(gidI)] = float4(tunmap(max(result, 0.0)), 1.0);
}

#define TAA_KERNEL(NAME, TS)                                                                                      \
groupshared float3 NAME##_tc[(TS + 2) * (TS + 2)];                                                                \
groupshared float NAME##_td[(TS + 2) * (TS + 2)];                                                                 \
[shader("compute")] [numthreads(TS, TS, 1)] void NAME(uint3 gid : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID, uint3 tg : SV_GroupID) \
{                                                                                                                 \
    const int TB = TS + 2;                                                                                        \
    uint uw, uh;                                                                                                  \
    gOut.GetDimensions(uw, uh);                                                                                   \
    int w = int(uw), h = int(uh);                                                                                 \
    int2 base = int2(tg.xy) * TS - 1;                                                                             \
    for (int i = int(tid.y) * TS + int(tid.x); i < TB * TB; i += TS * TS)                                         \
    {                                                                                                             \
        int2 p = clamp(base + int2(i % TB, i / TB), int2(0, 0), int2(w - 1, h - 1));                              \
        NAME##_tc[i] = rgb2ycocg(tmap(gCurrent.Load(int3(p, 0)).rgb));                                            \
        NAME##_td[i] = gDepth.Load(int3(p, 0));                                                                   \
    }                                                                                                             \
    GroupMemoryBarrierWithGroupSync();                                                                            \
    if (int(gid.x) >= w || int(gid.y) >= h) return;                                                               \
    float3 m1 = float3(0, 0, 0), m2 = float3(0, 0, 0), cur = float3(0, 0, 0);                                     \
    float closest = 0.0; int2 cOff = int2(0, 0);                                                                  \
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++)                                                   \
    {                                                                                                             \
        int j = (int(tid.y) + 1 + y) * TB + int(tid.x) + 1 + x;                                                   \
        float3 c = NAME##_tc[j];                                                                                  \
        m1 += c; m2 += c * c;                                                                                     \
        if (x == 0 && y == 0) cur = c;                                                                            \
        float d = NAME##_td[j];                                                                                   \
        if (d > closest) { closest = d; cOff = int2(x, y); }   /* reverse-Z: larger = closer */                   \
    }                                                                                                             \
    taaResolvePixel(int2(gid.xy), int2(tid.xy), TB, cur, m1, m2, closest, cOff, w, h);                            \
}

TAA_KERNEL(taaResolve16, 16)   // pw-entry: taaResolve16 compute
TAA_KERNEL(taaResolve8, 8)     // pw-entry: taaResolve8 compute

