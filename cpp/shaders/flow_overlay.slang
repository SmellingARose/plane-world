// CFD flow overlay (FLY): the LBM slice image as a world-space quad and tracer particles as camera-facing dots,
// drawn by pwflow_render's FlowOverlay after opaque geometry (alpha blended, depth tested, no depth writes).
// Bindings: b0 frame, b2 OverlayDraw; t5 slice image (RGBA8, sRGB-encoded turbo colours from lbmSlice);
// t9 tracers (2 float4 each: camera-relative position + radius, linear rgb + alpha).
#include "common.slang"

struct OverlayDraw {
    float4 origin;   // camera-relative corner of texel (0,0)
    float4 uEdge;    // world edge spanning the image width
    float4 vEdge;    // world edge spanning the image height
    float4 misc;     // x opacity, y brightness (HDR scale), z/w unused
};
ConstantBuffer<OverlayDraw> gOverlay : register(b2);
Texture2D<float4> gSlice : register(t5);
StructuredBuffer<float4> gTracers : register(t9);

float srgbToLinear1(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float3 srgbToLinear(float3 c) { return float3(srgbToLinear1(c.x), srgbToLinear1(c.y), srgbToLinear1(c.z)); }

struct SliceVOut { float4 position : SV_Position; float2 uv : TEXCOORD0; };
[shader("vertex")] SliceVOut flowSliceVertex(uint vid : SV_VertexID)
{
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1) };
    float2 c = corners[vid % 6];
    float3 rel = gOverlay.origin.xyz + gOverlay.uEdge.xyz * c.x + gOverlay.vEdge.xyz * c.y;
    SliceVOut o;
    o.position = mulM(gFrame.viewProj, float4(rel, 1.0));
    o.uv = c;
    return o;
}
[shader("fragment")] float4 flowSliceFragment(SliceVOut i) : SV_Target
{
    float4 s = gSlice.Sample(gPointClamp, i.uv);
    if (s.a < 0.01) discard;
    return float4(srgbToLinear(s.rgb) * gOverlay.misc.y, s.a * gOverlay.misc.x);
}

struct TracerVOut { float4 position : SV_Position; float2 uv : TEXCOORD0; float4 color : TEXCOORD1; };
[shader("vertex")] TracerVOut flowTracerVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 ps = gTracers[iid * 2], col = gTracers[iid * 2 + 1];
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid % 6];
    float3 right = float3(gFrame.view.c0.x, gFrame.view.c1.x, gFrame.view.c2.x);
    float3 up = float3(gFrame.view.c0.y, gFrame.view.c1.y, gFrame.view.c2.y);
    TracerVOut o;
    float3 rel = ps.xyz + (right * c.x + up * c.y) * ps.w;
    o.position = mulM(gFrame.viewProj, float4(rel, 1.0));
    o.uv = c; o.color = col;
    return o;
}
[shader("fragment")] float4 flowTracerFragment(TracerVOut i) : SV_Target
{
    float r2 = dot(i.uv, i.uv);
    if (r2 > 1.0) discard;
    return float4(i.color.rgb * gOverlay.misc.y, i.color.a * (1.0 - r2));
}
