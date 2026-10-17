// Water surface (ocean grid, lakes, rivers): displaced by the FFT ocean cascades (displacement / derivative
// texture arrays written from pw::water::OceanSimulation), river flow maps, Fresnel reflection of the sky,
// depth-based absorption + scattering (terrain depth texture), Jacobian and shoreline foam. Premultiplied alpha.
#include "env_common.slang"

struct WaterDraw {   // = pw::water::WaterDrawGPU
    float4 origin;    // camera-relative surface origin, wave amplitude scale
    float4 uvBase[3]; // per cascade: fractional camera offset (u, v), 0, fade distance
    float4 L;         // cascade patch sizes
    float4 depthTex;  // depth texture min corner (camera relative x, z), span, -camera.y
    float4 absorb;    // absorption rgb, scattering
    float4 misc;      // foam intensity, time, shoreline foam width, camera underwater
    float4 scatter;   // scatter tint rgb, sss strength
};
ConstantBuffer<WaterDraw> draw : register(b1);
struct WaterVertex { float px, py, pz, fx, fz, edge; };   // = pw::water::WaterVertex
StructuredBuffer<WaterVertex> verts : register(t8);
Texture2DArray<float4> dispTex : register(t1);    // Dx, h, Dz, foam
Texture2DArray<float4> derivTex : register(t2);   // dh/dx, dh/dz, dDx/dx, dDz/dz
Texture2D<float> depthTex : register(t3);          // terrain heights around the camera

struct VSOut {
    float4 pos : SV_Position;
    float3 rel : TEXCOORD0;
    float2 xz : TEXCOORD1;     // undisplaced camera-relative xz
    float2 flow : TEXCOORD2;
    float edge : TEXCOORD3;
};

float2 cascadeUV(float2 xzRel, int c) { return xzRel / draw.L[c] + draw.uvBase[c].xy; }

[shader("vertex")]
VSOut waterVS(uint vid : SV_VertexID) {
    WaterVertex v = verts[vid];
    float2 xz = draw.origin.xz + float2(v.px, v.pz);
    float3 d = float3(0.0);
    float dist = length(xz);
    for (int c = 0; c < 3; c++) {
        float fade = saturate(1.0 - dist / draw.uvBase[c].w);
        d += dispTex.SampleLevel(linearWrap, float3(cascadeUV(xz, c), float(c)), 0).xyz * fade;
    }
    d *= draw.origin.w;
    VSOut o;
    o.rel = float3(xz.x + d.x, draw.origin.y + v.py + d.y, xz.y + d.z);
    o.pos = mul(float4(o.rel, 1.0), frame.viewProj);
    o.xz = xz;
    o.flow = float2(v.fx, v.fz);
    o.edge = v.edge;
    return o;
}

[shader("fragment")]
float4 waterPS(VSOut i) : SV_Target {
    float4 dv = float4(0.0);
    float foam = 0.0;
    float dist = length(i.rel);
    float2 xz = i.xz - i.flow * frac(draw.misc.y / 8.0) * 8.0;
    for (int c = 0; c < 3; c++) {
        float fade = saturate(1.0 - dist / draw.uvBase[c].w);
        float3 uvw = float3(cascadeUV(xz, c), float(c));
        dv += derivTex.Sample(linearWrap, uvw) * fade;
        foam += dispTex.Sample(linearWrap, uvw).w * fade;
    }
    dv *= draw.origin.w;
    float3 n = normalize(float3(-dv.x / max(1.0 + dv.z, 0.2), 1.0, -dv.y / max(1.0 + dv.w, 0.2)));
    float3 viewDir = normalize(-i.rel);
    float cosT = saturate(dot(n, viewDir));
    float fresnel = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
    float3 r = reflect(-viewDir, n);
    float3 sky = lerp(frame.horizonColor.rgb, frame.skyColor.rgb, saturate(r.y * 1.5));
    float spec = pow(saturate(dot(r, frame.sunDir.xyz)), 600.0) * frame.sunDir.w * 4.0;
    // water depth from the terrain depth texture
    float2 duv = (i.rel.xz - draw.depthTex.xy) / draw.depthTex.z;
    float ground = depthTex.SampleLevel(linearClamp, duv, 0);
    float depth = max((i.rel.y - draw.depthTex.w) - ground, 0.0);
    float3 trans = exp(-draw.absorb.rgb * depth);
    float3 deep = draw.scatter.rgb * draw.absorb.w * frame.sunColor.rgb * frame.sunDir.w;
    float3 body = lerp(deep, float3(0.0), trans.g) + deep * (1.0 - trans.g);
    float shore = saturate(1.0 - depth / max(draw.misc.z, 1e-3)) * draw.misc.x;
    float f = saturate(foam * draw.misc.x + shore * (0.6 + 0.4 * hash12(floor(i.xz * 4.0 + draw.misc.y))));
    float3 color = lerp(body, sky, fresnel) + spec + f * float3(0.9, 0.93, 0.95);
    float alpha = saturate(max(1.0 - trans.g * (1.0 - fresnel), f)) * saturate(i.edge * 4.0);
    color = applyFog(color, i.rel);
    return float4(color * alpha, alpha);
}
