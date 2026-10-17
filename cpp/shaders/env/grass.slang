// Grass blades for pwenv_render's VegetationRenderable: 9 vertices (3 triangles) per blade generated from the vertex
// id over a density map (pw::veg::ProceduralVegetation::grassDensityMap), planted on the terrain, bent by wind.
// Bindings: b0 frame, b2 GrassDraw; t0..t4 frame textures; t5 density (R32F 0..1), t6 ground height (R32F, world heights).
#include "../common.slang"

DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);

float hashVeg(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

struct GrassDraw {
    float4 area;    // camera-relative min corner xz of the maps, texel (m), blades per texel
    float4 blade;   // height (m), width (m), map resolution, fade distance (m)
    float4 color;   // base linear rgb, tip lightness
    float4 extra;   // x: -camera.y (the ground texture holds world heights), yzw unused
};
ConstantBuffer<GrassDraw> gGrass : register(b2);
Texture2D<float> gGrassDensity : register(t5);
Texture2D<float> gGrassGround : register(t6);

struct GrassVOut {
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float t : TEXCOORD1;
    float3 normal : TEXCOORD2;
};

[shader("vertex")] GrassVOut grassVertex(uint vid : SV_VertexID)
{
    uint blade = vid / 9u, k = vid % 9u;
    uint res = uint(gGrass.blade.z);
    uint per = max(uint(gGrass.area.w), 1u);
    uint texel = blade / per, sub = blade % per;
    float2 cell = float2(float(texel % res), float(texel / res));
    float2 jitter = float2(hashVeg(cell + float(sub) * 1.7), hashVeg(cell.yx + float(sub) * 3.1));
    float2 uv = (cell + jitter) / float(res);
    float dens = gGrassDensity.SampleLevel(gLinearClamp, uv, 0.0);
    float2 xz = gGrass.area.xy + (cell + jitter) * gGrass.area.z;
    float fade = saturate(1.0 - length(xz) / gGrass.blade.w);
    GrassVOut o;
    o.rel = float3(0.0, 0.0, 0.0); o.t = 0.0; o.normal = float3(0.0, 1.0, 0.0);
    if (hashVeg(cell * 0.37 + float(sub)) > dens * fade) { o.position = float4(0.0, 0.0, -1.0, 1.0); return o; }
    float ground = gGrassGround.SampleLevel(gLinearClamp, uv, 0.0) + gGrass.extra.x;
    const uint lut[9] = { 0u, 1u, 2u, 2u, 1u, 3u, 2u, 3u, 4u };
    uint s = lut[k];
    float t = s == 4u ? 1.0 : float(s >> 1) * 0.5;
    float side = s == 4u ? 0.0 : (float(s & 1u) - 0.5);
    float yaw = hashVeg(cell + 9.1) * 6.2831853;
    float2 dirB = float2(cos(yaw), sin(yaw));
    float tt = gFrame.params.x;
    float2 bend = gFrame.wind.xz * 0.03 * (0.6 + 0.4 * sin(tt * 2.1 + xz.x * 0.3 + xz.y * 0.2));
    float hgt = gGrass.blade.x * (0.6 + 0.8 * hashVeg(cell * 1.3));
    float3 p = float3(xz.x, ground, xz.y);
    p.xz += float2(-dirB.y, dirB.x) * (side * gGrass.blade.y * (1.0 - t));
    p.y += hgt * t;
    p.xz += bend * (t * t * hgt);
    o.rel = p;
    o.position = mulM(gFrame.viewProj, float4(p, 1.0));
    o.t = t;
    o.normal = normalize(float3(dirB.x * 0.4, 1.0, dirB.y * 0.4));
    return o;
}

[shader("fragment")] float4 grassFragment(GrassVOut i) : SV_Target
{
    float3 albedo = gGrass.color.rgb * lerp(0.55, 1.0 + gGrass.color.w, i.t);
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 c = shadeSurfaceT(gSkyLUT, gShadowMap, i.rel, normalize(i.normal), albedo, 0.85, 0.0, lerp(0.5, 1.0, i.t), ap.sunT);
    c = c * ap.T + ap.L;
    return float4(c, 1.0);
}
