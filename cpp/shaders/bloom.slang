// Bloom (physically based mip chain).
#include "common.slang"

Texture2D<float4> gCurrent : register(t0);
RWTexture2D<float4> gOut : register(u8);

struct PostParams { uint flag; float radius; uint pad0; uint pad1; };
ConstantBuffer<PostParams> gPost : register(b1);

// ============================================================ bloom (physically based mip chain)
// down: t0 source (previous mip or the resolved HDR image), u8 destination mip; gPost.flag = 1 on the first pass.
[shader("compute")] [numthreads(8, 8, 1)] void bloomDownsample(uint3 gid : SV_DispatchThreadID)
{
    uint dw, dh, sw, sh;
    gOut.GetDimensions(dw, dh);
    gCurrent.GetDimensions(sw, sh);
    if (gid.x >= dw || gid.y >= dh) return;
    float2 ts = 1.0 / float2(float(sw), float(sh));
    float2 uv = (float2(gid.xy) + 0.5) / float2(float(dw), float(dh));
    Texture2D<float4> src = gCurrent;
    float3 a = src.SampleLevel(gLinearClamp, uv + ts * float2(-2, -2), 0).rgb, b = src.SampleLevel(gLinearClamp, uv + ts * float2(0, -2), 0).rgb;
    float3 c = src.SampleLevel(gLinearClamp, uv + ts * float2(2, -2), 0).rgb, d = src.SampleLevel(gLinearClamp, uv + ts * float2(-2, 0), 0).rgb;
    float3 e = src.SampleLevel(gLinearClamp, uv, 0).rgb, ff = src.SampleLevel(gLinearClamp, uv + ts * float2(2, 0), 0).rgb;
    float3 g = src.SampleLevel(gLinearClamp, uv + ts * float2(-2, 2), 0).rgb, hh = src.SampleLevel(gLinearClamp, uv + ts * float2(0, 2), 0).rgb;
    float3 ii = src.SampleLevel(gLinearClamp, uv + ts * float2(2, 2), 0).rgb;
    float3 j = src.SampleLevel(gLinearClamp, uv + ts * float2(-1, -1), 0).rgb, k = src.SampleLevel(gLinearClamp, uv + ts * float2(1, -1), 0).rgb;
    float3 l = src.SampleLevel(gLinearClamp, uv + ts * float2(-1, 1), 0).rgb, m = src.SampleLevel(gLinearClamp, uv + ts * float2(1, 1), 0).rgb;
    float3 r = e * 0.125 + (a + c + g + ii) * 0.03125 + (b + d + ff + hh) * 0.0625 + (j + k + l + m) * 0.125;
    if (gPost.flag != 0) r = min(r, float3(6.0e4, 6.0e4, 6.0e4));  // guard against inf / NaN fireflies
    r = max(r, 0.0);
    gOut[gid.xy] = float4(r, 1.0);
}
// up: t0 lower (smaller) mip, u8 destination mip (read-modify-write); gPost.radius in lower-mip texels.
[shader("compute")] [numthreads(8, 8, 1)] void bloomUpsample(uint3 gid : SV_DispatchThreadID)
{
    uint dw, dh, lw, lh;
    gOut.GetDimensions(dw, dh);
    gCurrent.GetDimensions(lw, lh);
    if (gid.x >= dw || gid.y >= dh) return;
    float2 uv = (float2(gid.xy) + 0.5) / float2(float(dw), float(dh));
    float2 t = gPost.radius / float2(float(lw), float(lh));
    Texture2D<float4> lower = gCurrent;
    float3 sum = lower.SampleLevel(gLinearClamp, uv, 0).rgb * 4.0;
    sum += (lower.SampleLevel(gLinearClamp, uv + float2(-t.x, 0), 0).rgb + lower.SampleLevel(gLinearClamp, uv + float2(t.x, 0), 0).rgb +
            lower.SampleLevel(gLinearClamp, uv + float2(0, -t.y), 0).rgb + lower.SampleLevel(gLinearClamp, uv + float2(0, t.y), 0).rgb) * 2.0;
    sum += lower.SampleLevel(gLinearClamp, uv + float2(-t.x, -t.y), 0).rgb + lower.SampleLevel(gLinearClamp, uv + float2(t.x, -t.y), 0).rgb +
           lower.SampleLevel(gLinearClamp, uv + float2(-t.x, t.y), 0).rgb + lower.SampleLevel(gLinearClamp, uv + float2(t.x, t.y), 0).rgb;
    float3 cur = gOut[gid.xy].rgb;
    gOut[gid.xy] = float4(cur + sum / 16.0, 1.0);
}

