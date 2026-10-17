// CDLOD terrain (Strugar 2009) for pwenv_render's TerrainRenderable. Every node selected on the CPU
// (pw::terrain::selectLOD) is one instance of the same N x N grid patch; vertices morph onto the parent grid with
// distance so LOD transitions are seamless. Heights come from the heightfield texture with the outside-falloff
// formula of HeightField::sampleHeight (CPU), so physics and pixels agree. Port of Sources/Terrain/TerrainShaders.swift.
// Bindings (pw/gpu.h): b0 frame, b1 cascade (shadow pass), b2 TerrainDraw; t0..t4 frame textures (bindFrame),
// t5 heights (R32F), t6 splat (RGBA8: grass, rock, sand/dirt, snow), t7 moisture (R32F); t8 nodes (2 float4 each).
#include "../common.slang"

struct TerrainDraw {
    float4 field;   // camera-relative world xz of sample (0,0), spacing (m), 1 / spacing
    float4 dims;    // width, height (samples), base level (m, camera relative), falloff (m)
    float4 grid;    // patch resolution (quads), 1 / resolution, camera y (world), unused
    float4 tint;    // albedo multiplier rgb, roughness
};
struct PassParams { uint cascade; uint pad0; uint pad1; uint pad2; };
ConstantBuffer<PassParams> gPass : register(b1);
ConstantBuffer<TerrainDraw> gDraw : register(b2);
DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);
Texture2D<float> gHeights : register(t5);     // world heights (m)
Texture2D<float4> gSplat : register(t6);
Texture2D<float> gMoisture : register(t7);
StructuredBuffer<float4> gNodes : register(t8);   // (origin.x, origin.z, size, level), (morphStart, morphEnd, minY, maxY)

float2 fieldUV(float2 xzRel) { return (xzRel - gDraw.field.xy) * gDraw.field.w; }   // sample units

// World height at camera-relative xz (same formula as HeightField::sampleHeight).
float sampleHeight(float2 xzRel) {
    float2 uv = fieldUV(xzRel);
    float2 maxUV = gDraw.dims.xy - 1.0;
    float2 c = clamp(uv, float2(0.0, 0.0), maxUV);
    float h = gHeights.SampleLevel(gLinearClamp, (c + 0.5) / gDraw.dims.xy, 0.0);
    float2 d = max(-uv, float2(0.0, 0.0)) + max(uv - maxUV, float2(0.0, 0.0));
    if (d.x == 0.0 && d.y == 0.0) return h;
    float t = smoothstep(0.0, gDraw.dims.w, length(d) * gDraw.field.z);
    return h + (gDraw.dims.z - h) * t;
}

float3 terrainNormal(float2 xzRel) {
    float e = gDraw.field.z;
    float hx = sampleHeight(xzRel + float2(e, 0.0)) - sampleHeight(xzRel - float2(e, 0.0));
    float hz = sampleHeight(xzRel + float2(0.0, e)) - sampleHeight(xzRel - float2(0.0, e));
    return normalize(float3(-hx, 2.0 * e, -hz));
}

float3 morphedPosition(uint vid, uint iid) {
    float4 n0 = gNodes[iid * 2], n1 = gNodes[iid * 2 + 1];
    uint res = uint(gDraw.grid.x), row = res + 1;
    float2 g = float2(float(vid % row), float(vid / row));
    float cell = n0.z * gDraw.grid.y;
    float2 xz = n0.xy + g * cell;
    float3 approx = float3(xz.x, sampleHeight(xz) - gDraw.grid.z, xz.y);
    float k = saturate((length(approx) - n1.x) / max(n1.y - n1.x, 1e-3));
    g -= frac(g * 0.5) * 2.0 * k;   // odd vertices slide onto the parent grid (CDLOD morphVertex)
    xz = n0.xy + g * cell;
    return float3(xz.x, sampleHeight(xz) - gDraw.grid.z, xz.y);
}

struct TerrainVOut {
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

[shader("vertex")] TerrainVOut terrainVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float3 p = morphedPosition(vid, iid);
    TerrainVOut o;
    o.position = mulM(gFrame.viewProj, float4(p, 1.0));
    o.rel = p;
    o.uv = (fieldUV(p.xz) + 0.5) / gDraw.dims.xy;
    return o;
}

float hashTerrain(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

[shader("fragment")] float4 terrainFragment(TerrainVOut i) : SV_Target
{
    float2 xzRel = i.rel.xz;
    float3 N = terrainNormal(xzRel);
    float4 w = gSplat.SampleLevel(gLinearClamp, i.uv, 0.0);
    w /= max(w.x + w.y + w.z + w.w, 1e-3);
    float wet = gMoisture.SampleLevel(gLinearClamp, i.uv, 0.0);
    float2 xzW = xzRel + gFrame.cameraWorld.xz;
    float detail = hashTerrain(floor(xzW * 2.0)) * 0.1 - 0.05;
    float macro = hashTerrain(floor(xzW / 37.0)) * 0.14 - 0.07;
    float3 grass = lerp(float3(0.16, 0.21, 0.07), float3(0.09, 0.16, 0.05), wet) * (1.0 + detail + macro);
    float3 rock = float3(0.30, 0.28, 0.25) * (1.0 + detail * 1.5 + macro);
    float3 sand = lerp(float3(0.55, 0.49, 0.36), float3(0.30, 0.25, 0.18), wet) * (1.0 + detail);
    float3 snow = float3(0.85, 0.87, 0.90);
    float3 albedo = (grass * w.x + rock * w.y + sand * w.z + snow * w.w) * gDraw.tint.rgb;
    float rough = lerp(gDraw.tint.a, 0.45, w.w);
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 c = shadeSurfaceT(gSkyLUT, gShadowMap, i.rel, N, albedo, rough, 0.0, 1.0, ap.sunT);
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}

struct TerrainShadowVOut { float4 position : SV_Position; };
[shader("vertex")] TerrainShadowVOut terrainShadowVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    TerrainShadowVOut o;
    o.position = mulM(gFrame.cascadeViewProj[gPass.cascade], float4(morphedPosition(vid, iid), 1.0));
    o.position.z = max(o.position.z, 0.0);   // pancaking
    return o;
}
