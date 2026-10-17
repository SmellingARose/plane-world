// Surface of a local FLIP fluid zone (pw::water::FluidZone): the particle density field (3D texture) is ray-marched
// inside the zone's box, the iso-surface found by bisection, normals from the density gradient, absorption along the
// view ray, Fresnel sky reflection; writes depth so it intersects the scene. Port of fluidBox* in WaterShaders.swift.
// Bindings: b0 frame, b2 FluidDraw; t0..t4 frame textures; t5 density (R32F 3D, particles per cell normalised).
#include "../common.slang"

struct FluidDraw {
    float4 originRel;   // camera-relative min corner
    float4 size;        // box size (m)
    float4 absorb;      // absorption rgb, scattering
    float4 params;      // cell size (m), iso level, unused, unused
};
ConstantBuffer<FluidDraw> gDraw : register(b2);
DepthTexture2DArray gShadowMap : register(t0);
Texture2D<float4> gSkyLUT : register(t1);
Texture3D<float4> gAerialL : register(t2);
Texture3D<float4> gAerialT : register(t3);
Texture3D<float4> gAerialS : register(t4);
Texture3D<float> gDensity : register(t5);

struct FluidVOut { float4 position : SV_Position; float3 rel : TEXCOORD0; };
[shader("vertex")] FluidVOut fluidBoxVertex(uint vid : SV_VertexID)
{
    const uint idx[36] = { 0,2,1, 1,2,3, 4,5,6, 5,7,6, 0,1,4, 1,5,4, 2,6,3, 3,6,7, 0,4,2, 2,4,6, 1,3,5, 3,7,5 };
    uint c = idx[vid % 36];
    float3 corner = float3(float(c & 1u), float((c >> 1) & 1u), float((c >> 2) & 1u));
    FluidVOut o;
    o.rel = gDraw.originRel.xyz + corner * gDraw.size.xyz;
    o.position = mulM(gFrame.viewProj, float4(o.rel, 1.0));
    return o;
}

float dens(float3 rel) { return gDensity.SampleLevel(gLinearClamp, (rel - gDraw.originRel.xyz) / gDraw.size.xyz, 0.0); }

struct FluidFOut { float4 color : SV_Target; float depth : SV_Depth; };
[shader("fragment")] FluidFOut fluidBoxFragment(FluidVOut i)
{
    float3 rd = normalize(i.rel);
    float3 bmin = gDraw.originRel.xyz, bmax = bmin + gDraw.size.xyz;
    float3 inv = 1.0 / rd;
    float3 t0 = bmin * inv, t1 = bmax * inv;
    float tn = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    float tf = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    tn = max(tn, gFrame.cameraForward.w);
    if (tf <= tn) discard;
    float stepLen = gDraw.params.x * 0.5, iso = gDraw.params.y;
    float t = tn, prevT = tn;
    bool hit = false;
    int maxSteps = int(min((tf - tn) / stepLen, 400.0)) + 1;
    for (int k = 0; k < maxSteps; k++) {
        if (dens(rd * t) > iso) { hit = true; break; }
        prevT = t; t += stepLen;
    }
    if (!hit) discard;
    float a = prevT, b = t;
    for (int k = 0; k < 5; k++) { float m = 0.5 * (a + b); if (dens(rd * m) > iso) b = m; else a = m; }
    float3 hitRel = rd * b;
    uint w, h, d;
    gDensity.GetDimensions(w, h, d);
    float3 e = gDraw.size.xyz / float3(float(w), float(h), float(d));
    float3 g = float3(dens(hitRel + float3(e.x, 0, 0)) - dens(hitRel - float3(e.x, 0, 0)),
                      dens(hitRel + float3(0, e.y, 0)) - dens(hitRel - float3(0, e.y, 0)),
                      dens(hitRel + float3(0, 0, e.z)) - dens(hitRel - float3(0, 0, e.z)));
    float3 N = length(g) > 1e-5 ? -normalize(g) : float3(0.0, 1.0, 0.0);
    float thick = 0.0, tt = b;
    for (int k = 0; k < 48 && tt < tf; k++) { if (dens(rd * tt) > iso) thick += stepLen * 2.0; tt += stepLen * 2.0; }
    float3 V = -rd;
    float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(N, V)), 5.0);
    float3 skyScale = gFrame.sunColor.rgb * gFrame.sunDir.w;
    float3 R = reflect(rd, N); R.y = abs(R.y);
    AerialSample ap = aerialLookup(gAerialL, gAerialT, gAerialS, hitRel);
    float3 sunE = skyScale * ap.sunT;
    float3 trans = exp(-gDraw.absorb.rgb * thick * 0.5);
    float3 body = float3(0.7, 0.9, 1.0) * gDraw.absorb.w * sunE * (1.0 - trans);
    float3 spec = D_GGX(saturate(dot(N, normalize(V + gFrame.sunDir.xyz))), 0.03) * 0.25 * sunE * saturate(dot(N, gFrame.sunDir.xyz));
    float3 c = lerp(body, sampleSky(gSkyLUT, R) * skyScale, fresnel) + spec;
    float alpha = saturate(1.0 - trans.g * (1.0 - fresnel) + 0.15);
    FluidFOut o;
    o.color = float4(c * ap.T + ap.L * alpha, alpha);
    float4 clip = mulM(gFrame.viewProj, float4(hitRel, 1.0));
    o.depth = clip.z / clip.w;
    return o;
}
