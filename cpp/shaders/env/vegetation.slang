// Vegetation for pwenv_render's VegetationRenderable (port of Sources/Vegetation/VegetationShaders.swift):
//  * trees: instanced bark + alpha-tested procedural leaf cards with wind sway; shadow-proxy depth pass
//  * octahedral impostors for far trees: bake (orthographic views into an albedo / normal atlas, MRT) and
//    camera-facing billboards that pick the nearest atlas frame
//  (grass blades: grass.slang)
// Bindings: b0 frame, b1 cascade (shadow pass), b2 TreeDraw; t0..t4 frame textures; t5 / t6 impostor atlas
// (albedo + coverage, tree-space normal); t8 MeshVertex (2 float4), t9 instances (3 float4: pos.xyz yaw |
// scale tint fall _ | rotation xyzw).
#include "../common.slang"

struct TreeDraw {
    float4 barkColor;   // linear rgb, roughness
    float4 leafColor;   // linear rgb, leaf kind (0 broadleaf, 1 needles, 2 frond, 3 birch)
    float4 params;      // tree height (m, scale 1), crown radius, wind response, time
    float4 impostor;    // frames per side, 1 / frames, half size (m, scale 1), centre height (m, scale 1)
    Mat bakeViewProj;   // impostor bake only: orthographic view-projection of the frame being baked
};
struct PassParams { uint cascade; uint pad0; uint pad1; uint pad2; };
ConstantBuffer<PassParams> gPass : register(b1);
ConstantBuffer<TreeDraw> gTree : register(b2);
DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);
Texture2D<float4> gAtlasAlbedo : register(t5);
Texture2D<float4> gAtlasNormal : register(t6);
StructuredBuffer<float4> gVertices : register(t8);
StructuredBuffer<float4> gInstances : register(t9);

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }

float hashVeg(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float3 windSway(float3 p, float height, float phase) {
    float h = saturate(p.y / max(height, 1.0));
    float3 w = gFrame.wind.xyz * 0.015 * gTree.params.z;
    float t = gFrame.params.x;
    float gust = sin(t * 1.3 + phase) * 0.5 + sin(t * 2.9 + phase * 1.7) * 0.25;
    return float3(w.x, 0.0, w.z) * (h * h * (1.0 + gust));
}

// Procedural leaf / needle / frond silhouette inside a card (uv.y < 0 flags leaves: uv.y = -(1 + 2 kind + v)).
float leafMask(float2 uv, float kind) {
    float2 c = uv * 2.0 - 1.0;
    if (kind < 0.5) return step(c.x * c.x * 1.6 + c.y * c.y * 0.81, 1.0);
    if (kind < 1.5) return step(abs(frac(c.x * 6.0) - 0.5), 0.18) * step(abs(c.y), 0.95);
    if (kind < 2.5) return step(abs(c.x), 0.25 + 0.45 * (1.0 - abs(frac(c.y * 5.0) - 0.5) * 2.0));
    return step(dot(c, c), 0.85);
}

struct TreeVOut {
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    nointerpolation float tint : TEXCOORD3;
};

void treeInstance(uint vid, uint iid, out float3 rel, out float3 n, out float2 uv, out float tint) {
    float4 a = gVertices[vid * 2], b = gVertices[vid * 2 + 1];
    float4 i0 = gInstances[iid * 3], i1 = gInstances[iid * 3 + 1], q = gInstances[iid * 3 + 2];
    float3 p = a.xyz * i1.x;
    if (i1.z < 0.5) p += windSway(p, gTree.params.x * i1.x, i0.w * 7.0);
    rel = i0.xyz + qrot(q, p);
    n = qrot(q, float3(a.w, b.x, b.y));
    uv = b.zw;
    tint = i1.y;
}

[shader("vertex")] TreeVOut treeVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    TreeVOut o;
    treeInstance(vid, iid, o.rel, o.normal, o.uv, o.tint);
    o.position = mulM(gFrame.viewProj, float4(o.rel, 1.0));
    return o;
}

float3 treeAlbedo(float2 uv, float tint, out float rough, out bool leaf) {
    leaf = uv.y < 0.0;
    if (leaf) {
        float t = -uv.y - 1.0;
        float kind = floor(t / 2.0);
        float vv = t - kind * 2.0;
        if (leafMask(float2(uv.x, vv), kind) < 0.5) discard;
        rough = 0.7;
        return gTree.leafColor.rgb * (0.75 + 0.5 * tint);
    }
    rough = gTree.barkColor.a;
    float bark = hashVeg(floor(float2(uv.x * 8.0, uv.y * 3.0))) * 0.3 + 0.8;
    return gTree.barkColor.rgb * bark;
}

[shader("fragment")] float4 treeFragment(TreeVOut i, bool front : SV_IsFrontFace) : SV_Target
{
    float rough; bool leaf;
    float3 albedo = treeAlbedo(i.uv, i.tint, rough, leaf);
    float3 N = normalize(front || !leaf ? i.normal : -i.normal);
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 c = shadeSurfaceT(gSkyLUT, gShadowMap, i.rel, N, albedo, rough, 0.0, leaf ? 0.8 : 1.0, ap.sunT);
    if (leaf) c += albedo * gFrame.sunColor.rgb * gFrame.sunDir.w * ap.sunT * 0.08 * saturate(dot(-N, gFrame.sunDir.xyz));   // translucency
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}

struct TreeShadowVOut { float4 position : SV_Position; };
[shader("vertex")] TreeShadowVOut treeShadowVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float3 rel, n; float2 uv; float tint;
    treeInstance(vid, iid, rel, n, uv, tint);
    TreeShadowVOut o;
    o.position = mulM(gFrame.cascadeViewProj[gPass.cascade], float4(rel, 1.0));
    o.position.z = max(o.position.z, 0.0);
    return o;
}

// ---- impostor bake: unlit albedo + coverage and the tree-space normal of one octahedral frame

struct BakeVOut {
    float4 position : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv : TEXCOORD1;
};
[shader("vertex")] BakeVOut impostorBakeVertex(uint vid : SV_VertexID)
{
    float4 a = gVertices[vid * 2], b = gVertices[vid * 2 + 1];
    BakeVOut o;
    o.position = mulM(gTree.bakeViewProj, float4(a.xyz, 1.0));
    o.normal = float3(a.w, b.x, b.y);
    o.uv = b.zw;
    return o;
}
struct BakeOut { float4 albedo : SV_Target0; float4 normal : SV_Target1; };
[shader("fragment")] BakeOut impostorBakeFragment(BakeVOut i, bool front : SV_IsFrontFace)
{
    float rough; bool leaf;
    float3 albedo = treeAlbedo(i.uv, 0.5, rough, leaf);
    float3 n = normalize(front || !leaf ? i.normal : -i.normal);
    BakeOut o;
    o.albedo = float4(albedo, 1.0);
    o.normal = float4(n * 0.5 + 0.5, leaf ? 0.8 : 1.0);
    return o;
}

// ---- impostors: one camera-facing quad per instance, nearest hemi-octahedral frame

struct ImpVOut {
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float2 uv : TEXCOORD1;
    nointerpolation float4 rot : TEXCOORD2;
    nointerpolation float tint : TEXCOORD3;
};

float2 octFrame(float3 dir, float frames) {
    dir.y = max(dir.y, 0.0);
    dir /= max(abs(dir.x) + abs(dir.y) + abs(dir.z), 1e-5);
    float2 uv = float2(dir.x + dir.z, dir.x - dir.z) * 0.5 + 0.5;
    return round(uv * (frames - 1.0));
}

[shader("vertex")] ImpVOut impostorVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 i0 = gInstances[iid * 3], i1 = gInstances[iid * 3 + 1], q = gInstances[iid * 3 + 2];
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1) };
    float2 cr = corners[vid % 6];
    float s = i1.x;
    float3 center = i0.xyz + float3(0.0, gTree.impostor.w * s, 0.0);
    float3 toCam = normalize(-center);
    float4 qi = float4(-q.xyz, q.w);
    float3 local = qrot(qi, toCam);                           // view direction in tree space
    float2 f = octFrame(local, gTree.impostor.x);
    // the bake camera's right / up for this frame (tree space), rotated back to world space
    float3 dirF = local;
    dirF.y = max(dirF.y, 0.0);
    float3 upRef = abs(dirF.y) > 0.99 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    float3 fw = normalize(-dirF);
    float3 rightL = normalize(cross(fw, upRef));
    float3 upL = cross(rightL, fw);
    float hs = gTree.impostor.z * s;
    float3 offs = qrot(q, rightL * ((cr.x - 0.5) * 2.0 * hs) + upL * ((cr.y - 0.5) * 2.0 * hs));
    ImpVOut o;
    o.rel = center + offs;
    o.position = mulM(gFrame.viewProj, float4(o.rel, 1.0));
    o.uv = (f + float2(cr.x, 1.0 - cr.y)) * gTree.impostor.y;
    o.rot = q;
    o.tint = i1.y;
    return o;
}

[shader("fragment")] float4 impostorFragment(ImpVOut i) : SV_Target
{
    float4 a = gAtlasAlbedo.SampleLevel(gLinearClamp, i.uv, 0.0);
    if (a.a < 0.5) discard;
    float4 nn = gAtlasNormal.SampleLevel(gLinearClamp, i.uv, 0.0);
    float3 N = normalize(qrot(i.rot, nn.xyz * 2.0 - 1.0));
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 albedo = a.rgb * (0.75 + 0.5 * i.tint) / 1.0;
    float3 c = shadeSurfaceT(gSkyLUT, gShadowMap, i.rel, N, albedo, 0.75, 0.0, nn.a, ap.sunT);
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}
