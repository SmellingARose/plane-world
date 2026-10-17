// Water surface for pwenv_render's WaterRenderable (port of the surface shaders in Sources/Water/WaterShaders.swift):
// ocean grid / lake / river meshes displaced by the three FFT cascades (pw::water::OceanSimulation), river flow,
// Fresnel sky reflection (sky-view LUT), sun glint, depth absorption + scattering (terrain depth texture),
// Jacobian and shoreline foam, aerial perspective. Alpha blended after opaque geometry.
// Bindings: b0 frame, b2 WaterDraw; t0..t4 frame textures; t5 displacement array (Dx, h, Dz, foam), t6 derivative
// array (dh/dx, dh/dz, dDx/dx, dDz/dz), t7 terrain heights around the camera (R32F); t8 vertices (2 float4 each:
// px py pz edge | fx fz 0 0, relative to the draw origin).
#include "../common.slang"

struct WaterDraw {   // = pw::water::WaterDrawGPU
    float4 origin;    // camera-relative surface origin, wave amplitude scale
    float4 uvBase[3]; // per cascade: fractional camera offset (u, v), 0, fade distance
    float4 L;         // cascade patch sizes
    float4 depthTex;  // depth texture min corner (camera relative x, z), span, -camera.y
    float4 absorb;    // absorption rgb, scattering
    float4 misc;      // foam intensity, time, shoreline foam width, camera underwater
    float4 scatter;   // scatter tint rgb, sss strength
};
ConstantBuffer<WaterDraw> gDraw : register(b2);
DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);
Texture2DArray<float4> gDisp : register(t5);
Texture2DArray<float4> gDeriv : register(t6);
Texture2D<float> gGround : register(t7);
StructuredBuffer<float4> gVerts : register(t8);

// Bilinear sample with wrap-around in both axes (the shared samplers clamp V), cascades are periodic tiles.
float4 sampleWrap(Texture2DArray<float4> tex, float2 xzRel, int c)
{
    uint w, h, layers;
    tex.GetDimensions(w, h, layers);
    float2 p = (xzRel / gDraw.L[c] + gDraw.uvBase[c].xy) * float2(float(w), float(h)) - 0.5;
    float2 f = floor(p), t = p - f;
    int2 i0 = int2(f);
    int2 m = int2(int(w) - 1, int(h) - 1);
    int2 a = i0 & m, b = (i0 + 1) & m;
    float4 s00 = tex.Load(int4(a.x, a.y, c, 0)), s10 = tex.Load(int4(b.x, a.y, c, 0));
    float4 s01 = tex.Load(int4(a.x, b.y, c, 0)), s11 = tex.Load(int4(b.x, b.y, c, 0));
    return lerp(lerp(s00, s10, t.x), lerp(s01, s11, t.x), t.y);
}

struct WaterVOut {
    float4 position : SV_Position;
    float3 rel : TEXCOORD0;
    float2 xz : TEXCOORD1;
    float2 flow : TEXCOORD2;
    float edge : TEXCOORD3;
};

[shader("vertex")] WaterVOut waterVertex(uint vid : SV_VertexID)
{
    float4 a = gVerts[vid * 2], b = gVerts[vid * 2 + 1];
    float2 xz = gDraw.origin.xz + a.xz;
    float dist = length(xz);
    float3 d = float3(0.0, 0.0, 0.0);
    for (int c = 0; c < 3; c++) {
        float fade = saturate(1.0 - dist / gDraw.uvBase[c].w);
        d += sampleWrap(gDisp, xz, c).xyz * fade;
    }
    d *= gDraw.origin.w;
    WaterVOut o;
    o.rel = float3(xz.x + d.x, gDraw.origin.y + a.y + d.y, xz.y + d.z);
    o.position = mulM(gFrame.viewProj, float4(o.rel, 1.0));
    o.xz = xz;
    o.flow = b.xy;
    o.edge = a.w;
    return o;
}

[shader("fragment")] float4 waterFragment(WaterVOut i) : SV_Target
{
    float dist = length(i.rel);
    float t = gDraw.misc.y;
    float2 xz = i.xz - i.flow * frac(t / 8.0) * 8.0;
    float4 dv = float4(0.0, 0.0, 0.0, 0.0);
    float foam = 0.0;
    for (int c = 0; c < 3; c++) {
        float fade = saturate(1.0 - dist / gDraw.uvBase[c].w);
        dv += sampleWrap(gDeriv, xz, c) * fade;
        foam += sampleWrap(gDisp, xz, c).w * fade;
    }
    dv *= gDraw.origin.w;
    float3 N = normalize(float3(-dv.x / max(1.0 + dv.z, 0.2), 1.0, -dv.y / max(1.0 + dv.w, 0.2)));
    float3 V = normalize(-i.rel);
    float cosT = saturate(dot(N, V));
    float fresnel = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
    float3 R = reflect(-V, N);
    R.y = abs(R.y);
    float3 skyScale = gFrame.sunColor.rgb * gFrame.sunDir.w;
    float3 sky = sampleSky(gSkyLUT, R) * skyScale;
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 sunE = skyScale * ap.sunT;
    float3 H = normalize(V + gFrame.sunDir.xyz);
    float NoH = saturate(dot(N, H));
    float spec = D_GGX(NoH, 0.02) * 0.25 * saturate(dot(N, gFrame.sunDir.xyz));
    // water depth from the terrain heights around the camera
    float2 duv = (i.rel.xz - gDraw.depthTex.xy) / gDraw.depthTex.z;
    float ground = gGround.SampleLevel(gLinearClamp, duv, 0.0) + gDraw.depthTex.w;   // camera relative
    bool hasGround = all(duv > 0.0) && all(duv < 1.0);
    float depth = hasGround ? max(i.rel.y - ground, 0.0) : 1000.0;
    float3 trans = exp(-gDraw.absorb.rgb * depth);
    float3 deep = gDraw.scatter.rgb * gDraw.absorb.w * sunE * (0.4 + 0.6 * saturate(gFrame.sunDir.y));
    float shore = hasGround ? saturate(1.0 - depth / max(gDraw.misc.z, 1e-3)) : 0.0;
    float2 cell = floor(i.xz * 4.0 + t);
    float n = frac(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453);
    float f = saturate(foam * gDraw.misc.x + shore * gDraw.misc.x * (0.6 + 0.4 * n));
    float3 body = deep * (1.0 - trans.g);
    float3 color = lerp(body, sky, fresnel) + spec * sunE + f * sunE * 0.25;
    float alpha = saturate(max(1.0 - trans.g * (1.0 - fresnel), f)) * saturate(i.edge * 4.0);
    color = color * ap.T + ap.L * alpha;
    return float4(color, alpha);
}

// ---- splash spray: camera-facing soft discs (t9: 2 float4 per particle: camera-relative pos + size, alpha)
StructuredBuffer<float4> gSplash : register(t9);
struct SplashVOut { float4 position : SV_Position; float2 uv : TEXCOORD0; float alpha : TEXCOORD1; float3 rel : TEXCOORD2; };
[shader("vertex")] SplashVOut splashVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 ps = gSplash[iid * 2], misc = gSplash[iid * 2 + 1];
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid % 6];
    float3 right = float3(gFrame.view.c0.x, gFrame.view.c1.x, gFrame.view.c2.x);
    float3 up = float3(gFrame.view.c0.y, gFrame.view.c1.y, gFrame.view.c2.y);
    SplashVOut o;
    o.rel = ps.xyz + (right * c.x + up * c.y) * ps.w;
    o.position = mulM(gFrame.viewProj, float4(o.rel, 1.0));
    o.uv = c; o.alpha = misc.x;
    return o;
}
[shader("fragment")] float4 splashFragment(SplashVOut i) : SV_Target
{
    float r2 = dot(i.uv, i.uv);
    if (r2 > 1.0) discard;
    float a = i.alpha * (1.0 - r2) * (1.0 - r2);
    float3 skyScale = gFrame.sunColor.rgb * gFrame.sunDir.w;
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, i.rel);
    float3 amb = sampleSky(gSkyLUT, float3(0.0, 1.0, 0.0)) * skyScale * PI * 0.5;
    float3 c = 0.8 * (skyScale * ap.sunT * 0.6 + amb) / PI;
    c = c * ap.T + ap.L;
    return float4(c, a);
}
