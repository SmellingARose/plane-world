// Shared declarations of the env render shaders (terrain / water / vegetation). Binding contract with the renderer
// (P3a render core): b0 = EnvFrame (per frame), b1/b2 = per-draw constants, t0..t7 = textures, t8/t9 = vertex /
// instance StructuredBuffers (Metal: buffer(8)/buffer(9), so they never alias the constant buffers),
// s0 = linear-wrap sampler, s1 = linear-clamp sampler. Positions are camera-relative (camera at the origin) so
// large worlds keep float precision; depth is reversed-Z [1 at near, 0 at far] as in the Swift renderer.
#pragma once

struct EnvFrame {
    float4x4 viewProj;        // camera-relative world -> clip (row-vector convention: mul(float4(p, 1), viewProj))
    float4 cameraPos;         // world position (xyz), time (s)
    float4 sunDir;            // towards the sun (xyz), sun intensity
    float4 sunColor;          // rgb, ambient strength
    float4 skyColor;          // zenith rgb, horizon blend
    float4 horizonColor;      // rgb, unused
    float4 fog;               // density, height falloff, max opacity, unused
    float4 wind;              // xz direction * speed (m/s), gust phase, unused
};
ConstantBuffer<EnvFrame> frame : register(b0);
SamplerState linearWrap : register(s0);
SamplerState linearClamp : register(s1);

float3 applyFog(float3 color, float3 rel) {
    float d = length(rel);
    float h = frame.cameraPos.y + rel.y * 0.5;
    float f = 1.0 - exp(-d * frame.fog.x * 1e-4 * exp(-max(h, 0.0) * frame.fog.y * 1e-3));
    float3 skyMix = lerp(frame.horizonColor.rgb, frame.skyColor.rgb, saturate(normalize(rel).y * 2.0));
    return lerp(color, skyMix, min(f, frame.fog.z));
}

float3 lambertSky(float3 albedo, float3 n, float shadow) {
    float ndl = saturate(dot(n, frame.sunDir.xyz));
    float3 ambient = lerp(frame.horizonColor.rgb, frame.skyColor.rgb, n.y * 0.5 + 0.5) * frame.sunColor.w;
    return albedo * (frame.sunColor.rgb * frame.sunDir.w * ndl * shadow + ambient);
}

float hash12(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}
