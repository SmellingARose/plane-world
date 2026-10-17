// Scene passes (port of Sources/Render/RendererShaders.swift): PBR mesh, shadow depth, sky, debug lines.
#include "common.slang"

// Vertex pulling: t8 vertices (2 float4: px py pz nx | ny nz u v), t9 instances (6 float4: model columns c0..c3,
// colour (rgb linear albedo, a roughness), material (x metallic, y emissive, z pattern id)).
StructuredBuffer<float4> gVertices : register(t8);
StructuredBuffer<float4> gInstances : register(t9);
DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);

struct PassParams { uint cascade; uint pad0; uint pad1; uint pad2; };
ConstantBuffer<PassParams> gPass : register(b1);

static const uint kInstanceStride = 6;

Mat instanceModel(uint iid)
{
    uint b = iid * kInstanceStride;
    Mat m;
    m.c0 = gInstances[b]; m.c1 = gInstances[b + 1]; m.c2 = gInstances[b + 2]; m.c3 = gInstances[b + 3];
    return m;
}

// ============================================================ PBR mesh
struct MeshVOut
{
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    nointerpolation float4 color : TEXCOORD3;
    nointerpolation float4 material : TEXCOORD4;
};

[shader("vertex")] MeshVOut meshVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 a = gVertices[vid * 2], b = gVertices[vid * 2 + 1];
    Mat model = instanceModel(iid);
    float4 wp = mulM(model, float4(a.xyz, 1.0));
    MeshVOut o;
    o.position = mulM(gFrame.viewProj, wp);
    o.rel = wp.xyz;
    o.normal = mulM3(model, float3(a.w, b.x, b.y));
    o.uv = b.zw;
    o.color = gInstances[iid * kInstanceStride + 4];
    o.material = gInstances[iid * kInstanceStride + 5];
    return o;
}

float3 groundPattern(float3 rel, float3 base)
{
    float2 w = rel.xz + gFrame.cameraWorld.xz;
    float2 g1 = abs(frac(w / 10.0 + 0.5) - 0.5) * 10.0;      // 10 m grid
    float2 g2 = abs(frac(w / 100.0 + 0.5) - 0.5) * 100.0;    // 100 m grid
    float px = length(rel) * 0.0015 + 0.02;
    float l1 = 1.0 - smoothstep(0.0, px * 2.0 + 0.03, min(g1.x, g1.y));
    float l2 = 1.0 - smoothstep(0.0, px * 3.0 + 0.08, min(g2.x, g2.y));
    float n = frac(sin(dot(floor(w / 2.0), float2(12.9898, 78.233))) * 43758.5453);
    float3 c = base * (0.9 + 0.2 * n);
    c = lerp(c, c * 0.55, l1 * 0.6);
    c = lerp(c, c * 0.35, l2 * 0.8);
    return c;
}

[shader("fragment")] float4 meshFragment(MeshVOut i) : SV_Target
{
    float3 N = normalize(i.normal);
    float3 albedo = i.color.rgb;
    if (i.material.z > 0.5 && i.material.z < 1.5) albedo = groundPattern(i.rel, albedo);
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 c = shadeSurfaceT(gSkyLUT, gShadowMap, i.rel, N, albedo, i.color.a, i.material.x, 1.0, ap.sunT);
    c += i.color.rgb * i.material.y;                            // emissive
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}

// ============================================================ shadow depth
struct ShadowVOut { float4 position : SV_Position; };
[shader("vertex")] ShadowVOut shadowVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 wp = mulM(instanceModel(iid), float4(gVertices[vid * 2].xyz, 1.0));
    ShadowVOut o;
    o.position = mulM(gFrame.cascadeViewProj[gPass.cascade], wp);
    o.position.z = max(o.position.z, 0.0);                     // pancaking: casters behind the near plane
    return o;
}

// ============================================================ sky (fullscreen, drawn after opaque geometry at z = 0)
[shader("vertex")] FSOut fullscreenVertex(uint vid : SV_VertexID) { return fullscreenTriangle(vid); }

[shader("fragment")] float4 skyFragment(FSOut i) : SV_Target
{
    float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
    float4 h = mulM(gFrame.invViewProj, float4(ndc, 1.0, 1.0));
    float3 rd = normalize(h.xyz / h.w);
    float3 c = sampleSky(gSkyLUT, rd) * gFrame.sunColor.rgb * gFrame.sunDir.w;
    // Sun disk with limb darkening, attenuated by atmospheric transmittance.
    float cosA = dot(rd, gFrame.sunDir.xyz), r = gFrame.sunColor.w;
    float d = acos(clamp(cosA, -1.0, 1.0)) / r;
    if (d < 1.0)
    {
        float mu = sqrt(max(0.0, 1.0 - d * d));
        float3 limb = pow(float3(mu, mu, mu), float3(0.397, 0.503, 0.652));
        float3 T = transmittanceToSun(planetPos(float3(0.0, 0.0, 0.0)), rd);
        float tG = raySphereNear(planetPos(float3(0.0, 0.0, 0.0)), rd, Rg);
        if (tG < 0.0) c += gFrame.sunColor.rgb * gFrame.sunDir.w * T * limb * 4000.0 * smoothstep(1.0, 0.9, d);
    }
    return float4(c, 1.0);
}

// ============================================================ debug lines (t8: 2 float4 per vertex: xyz_, rgba)
struct LineVOut { float4 position : SV_Position; float4 color : COLOR0; };
[shader("vertex")] LineVOut lineVertex(uint vid : SV_VertexID)
{
    LineVOut o;
    o.position = mulM(gFrame.viewProj, float4(gVertices[vid * 2].xyz, 1.0));
    o.color = gVertices[vid * 2 + 1];
    return o;
}
[shader("fragment")] float4 lineFragment(LineVOut i) : SV_Target { return i.color; }
