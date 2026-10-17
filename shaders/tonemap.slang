// Tonemap (ACES fitted, Hill) + bloom composite + dither -> RGBA8.
#include "common.slang"

Texture2D<float4> gCurrent : register(t0);
// t0 resolved HDR, t1 bloom mip 0. Output RGBA8: linear -> sRGB encoded here when quality.z = 1 (the target is
// UNORM so Qt Quick can composite it unchanged on every backend).
Texture2D<float4> gBloom : register(t1);
float3 RRTAndODTFit(float3 v) { float3 a = v * (v + 0.0245786) - 0.000090537; float3 b = v * (0.983729 * v + 0.4329510) + 0.238081; return a / b; }
float3 acesFitted(float3 c)
{
    // ACESIn / ACESOut as column vectors (MSL float3x3 column constructors in the Swift renderer).
    c = float3(0.59719, 0.07600, 0.02840) * c.x + float3(0.35458, 0.90834, 0.13383) * c.y + float3(0.04823, 0.01566, 0.83777) * c.z;
    c = RRTAndODTFit(c);
    c = float3(1.60475, -0.10208, -0.00327) * c.x + float3(-0.53108, 1.10813, -0.07276) * c.y + float3(-0.07367, -0.00605, 1.07602) * c.z;
    return saturate(c);
}
float srgbEncode(float x) { return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055; }

[shader("vertex")] FSOut tonemapVertex(uint vid : SV_VertexID) { return fullscreenTriangle(vid); }

[shader("fragment")] float4 tonemapFragment(FSOut i) : SV_Target
{
    float3 c = gCurrent.SampleLevel(gLinearClamp, i.uv, 0).rgb;
    float3 b = gBloom.SampleLevel(gLinearClamp, i.uv, 0).rgb;
    c = lerp(c, b, gFrame.atmos.w);
    c *= gFrame.params.y;
    c = acesFitted(c);
    // Triangular dither against banding in the sky gradient.
    float n = frac(sin(dot(i.position.xy + gFrame.params.x, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    c += n / 255.0;
    if (gFrame.quality.z > 0.5) c = float3(srgbEncode(saturate(c.r)), srgbEncode(saturate(c.g)), srgbEncode(saturate(c.b)));
    return float4(c, 1.0);
}
