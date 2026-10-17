// Vegetation: instanced procedural trees (bark + alpha-tested leaf cards with wind sway), octahedral impostors
// for far trees (atlas baked by rendering treeVS/treePS with pw::veg::impostor::bakeViewProj per frame), and GPU
// grass blades generated from the vertex id over a density map (pw::veg::ProceduralVegetation::grassDensityMap)
// bent by wind and interaction splats.
#include "env_common.slang"

struct MeshVertex { float px, py, pz, nx, ny, nz, u, v; };                              // = pw::veg::MeshVertex
struct TreeInstance { float3 pos; float yaw; float scale; float tint; float fall; float pad; float4 rot; };   // = pw::veg::TreeInstanceGPU
struct TreeDraw {
    float4 barkColor;      // rgb, roughness
    float4 leafColor;      // rgb, leaf kind
    float4 lod;            // impostor frames, 1 / frames, impostor size (m), fade
    float4 params;         // height (m), crown radius, wind response, unused
};
ConstantBuffer<TreeDraw> draw : register(b1);
StructuredBuffer<MeshVertex> meshVerts : register(t8);
StructuredBuffer<TreeInstance> instances : register(t9);
Texture2D<float4> impostorAlbedo : register(t2);   // frames x frames atlas, alpha = coverage
Texture2D<float4> impostorNormal : register(t3);   // packed normal (xyz * 0.5 + 0.5), depth
Texture2D<float> grassDensity : register(t4);       // 0..1 around the camera
Texture2D<float4> grassInteract : register(t5);     // xy push direction, z flatten, w unused

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }

float3 windSway(float3 p, float height, float phase) {
    float h = saturate(p.y / max(height, 1.0));
    float2 w = frame.wind.xz * 0.02 * draw.params.z;
    float gust = sin(frame.cameraPos.w * 1.3 + phase) * 0.5 + sin(frame.cameraPos.w * 2.9 + phase * 1.7) * 0.25;
    return float3(w.x, 0.0, w.y) * h * h * (1.0 + gust);
}

struct TreeOut {
    float4 pos : SV_Position;
    float3 rel : TEXCOORD0;
    float3 n : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float tint : TEXCOORD3;
};

[shader("vertex")]
TreeOut treeVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    MeshVertex v = meshVerts[vid];
    TreeInstance inst = instances[iid];
    float3 p = float3(v.px, v.py, v.pz) * inst.scale;
    if (inst.fall == 0.0) p += windSway(p, draw.params.x * inst.scale, inst.yaw * 7.0);
    TreeOut o;
    o.rel = inst.pos + qrot(inst.rot, p);
    o.n = qrot(inst.rot, float3(v.nx, v.ny, v.nz));
    o.pos = mul(float4(o.rel, 1.0), frame.viewProj);
    o.uv = float2(v.u, v.v);
    o.tint = inst.tint;
    return o;
}

// Procedural leaf / needle / frond silhouette inside a card (uv.y < 0 flags leaves: uv.y = -(1 + 2 kind + v)).
float leafMask(float2 uv, float kind) {
    float2 c = uv * 2.0 - 1.0;
    if (kind < 0.5) return step(c.x * c.x * 1.6 + (c.y * 0.9) * (c.y * 0.9), 1.0);                       // broadleaf
    if (kind < 1.5) return step(abs(frac(c.x * 6.0) - 0.5), 0.18) * step(abs(c.y), 0.95);                 // needles
    if (kind < 2.5) return step(abs(c.x), 0.25 + 0.75 * (1.0 - abs(frac(c.y * 5.0) - 0.5) * 2.0) * 0.6); // frond
    return step(dot(c, c), 0.85);                                                                         // birch
}

[shader("fragment")]
float4 treePS(TreeOut i, bool front : SV_IsFrontFace) : SV_Target {
    float3 n = normalize(front ? i.n : -i.n);
    float3 albedo;
    if (i.uv.y < 0.0) {
        float t = -i.uv.y - 1.0;
        float kind = floor(t / 2.0);
        float vv = t - kind * 2.0;
        if (leafMask(float2(i.uv.x, vv), kind) < 0.5) discard;
        albedo = draw.leafColor.rgb * (0.8 + 0.4 * i.tint);
    } else {
        float bark = hash12(floor(float2(i.uv.x * 8.0, i.uv.y * 3.0))) * 0.25 + 0.85;
        albedo = draw.barkColor.rgb * bark;
    }
    float3 c = lambertSky(albedo, n, 1.0);
    return float4(applyFog(c, i.rel), 1.0);
}

// ---- impostors: camera-facing quad per instance, frame chosen from the hemi-octahedral view direction

struct ImpOut {
    float4 pos : SV_Position;
    float3 rel : TEXCOORD0;
    float2 uv : TEXCOORD1;
    float tint : TEXCOORD2;
};

float2 octFrame(float3 dir, float frames) {
    dir.y = max(dir.y, 0.0);
    dir /= max(abs(dir.x) + abs(dir.y) + abs(dir.z), 1e-5);
    float2 uv = float2(dir.x + dir.z, dir.x - dir.z) * 0.5 + 0.5;
    return round(uv * (frames - 1.0));
}

[shader("vertex")]
ImpOut impostorVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    TreeInstance inst = instances[iid];
    float2 corner = float2(float((vid >> 1) & 1u ^ (vid & 1u)), float(vid >= 2u && vid <= 4u ? 1u : 0u));   // 2 triangles
    float size = draw.lod.z * inst.scale;
    float3 center = inst.pos + float3(0.0, draw.params.x * inst.scale * 0.5, 0.0);
    float3 toCam = normalize(-center);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), toCam));
    float3 up = cross(toCam, right);
    ImpOut o;
    o.rel = center + (right * (corner.x - 0.5) + up * (corner.y - 0.5)) * size;
    o.pos = mul(float4(o.rel, 1.0), frame.viewProj);
    float3 local = qrot(float4(-inst.rot.xyz, inst.rot.w), toCam);
    float2 f = octFrame(local, draw.lod.x);
    o.uv = (f + float2(corner.x, 1.0 - corner.y)) * draw.lod.y;
    o.tint = inst.tint;
    return o;
}

[shader("fragment")]
float4 impostorPS(ImpOut i) : SV_Target {
    float4 a = impostorAlbedo.Sample(linearClamp, i.uv);
    if (a.a < 0.5) discard;
    float3 n = normalize(impostorNormal.Sample(linearClamp, i.uv).xyz * 2.0 - 1.0);
    float3 c = lambertSky(a.rgb * (0.85 + 0.3 * i.tint), n, 1.0);
    return float4(applyFog(c, i.rel), 1.0);
}

// ---- grass: blades generated from the vertex id (5 vertices per blade as a strip of 3 triangles)

struct GrassDraw {
    float4 area;      // camera-relative min corner xz of the density map, texel (m), blades per texel
    float4 blade;     // height (m), width (m), map resolution, density threshold
    float4 color;     // base rgb, tip lightness
};
ConstantBuffer<GrassDraw> grass : register(b2);
Texture2D<float> groundHeight : register(t6);   // terrain heights matching the density map (relative to camera y)

struct GrassOut {
    float4 pos : SV_Position;
    float3 rel : TEXCOORD0;
    float t : TEXCOORD1;
    float3 n : TEXCOORD2;
};

[shader("vertex")]
GrassOut grassVS(uint vid : SV_VertexID) {
    uint blade = vid / 9u, k = vid % 9u;
    uint res = uint(grass.blade.z);
    uint perTexel = max(uint(grass.area.w), 1u);
    uint texel = blade / perTexel;
    float2 cell = float2(float(texel % res), float(texel / res));
    float2 jitter = float2(hash12(cell + float(blade % perTexel) * 1.7), hash12(cell.yx + float(blade % perTexel) * 3.1));
    float2 uv = (cell + jitter) / float(res);
    float dens = grassDensity.SampleLevel(linearClamp, uv, 0);
    GrassOut o;
    if (hash12(cell * 0.37 + float(blade % perTexel)) > dens) { o.pos = float4(0, 0, -1, 1); o.rel = 0; o.t = 0; o.n = float3(0, 1, 0); return o; }
    float2 xz = grass.area.xy + (cell + jitter) * grass.area.z;
    float ground = groundHeight.SampleLevel(linearClamp, uv, 0);
    // strip: 3 segments, (k / 2) height level, k odd = right edge; triangle list expansion of the strip
    const uint lut[9] = {0u, 1u, 2u, 2u, 1u, 3u, 2u, 3u, 4u};
    uint s = lut[k];
    float t = float(s >> 1) / 2.0;
    if (s == 4u) t = 1.0;
    float side = (s == 4u) ? 0.0 : (float(s & 1u) - 0.5);
    float yaw = hash12(cell + 9.1) * 6.2831853;
    float2 dirB = float2(cos(yaw), sin(yaw));
    float4 inter = grassInteract.SampleLevel(linearClamp, uv, 0);
    float2 bend = frame.wind.xz * 0.03 * (0.6 + 0.4 * sin(frame.cameraPos.w * 2.1 + xz.x * 0.3 + xz.y * 0.2)) + inter.xy;
    float hgt = grass.blade.x * (0.6 + 0.8 * hash12(cell * 1.3)) * (1.0 - inter.z * 0.8);
    float3 p = float3(xz.x, ground, xz.y);
    p.xz += float2(-dirB.y, dirB.x) * side * grass.blade.y * (1.0 - t);
    p.y += hgt * t;
    p.xz += bend * t * t * hgt;
    o.rel = p;
    o.pos = mul(float4(p, 1.0), frame.viewProj);
    o.t = t;
    o.n = normalize(float3(dirB.x, 0.6, dirB.y));
    return o;
}

[shader("fragment")]
float4 grassPS(GrassOut i) : SV_Target {
    float3 albedo = grass.color.rgb * lerp(0.55, 1.0 + grass.color.w, i.t);
    float3 c = lambertSky(albedo, normalize(i.n), 1.0);
    return float4(applyFog(c, i.rel), 1.0);
}
