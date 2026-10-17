// Atmosphere LUTs (compute; may run on the async compute queue): sky-view LUT 256x128 and the 64x64x48
// aerial-perspective LUTs (inscatter, view transmittance, sun transmittance).
#include "common.slang"

RWTexture2D<float4> gSkyOut : register(u8);
RWTexture3D<float4> gAerialOutL : register(u9);
RWTexture3D<float4> gAerialOutT : register(u10);
RWTexture3D<float4> gAerialOutS : register(u11);

[shader("compute")] [numthreads(16, 8, 1)] void skyViewLUT(uint3 gid : SV_DispatchThreadID)
{
    uint w, h;
    gSkyOut.GetDimensions(w, h);
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid.xy) + 0.5) / float2(float(w), float(h));
    float3 rd = skyLUTDir(uv);
    float3 ro = planetPos(float3(0.0, 0.0, 0.0));
    float tG = raySphereNear(ro, rd, Rg);
    float tT = raySphereFar(ro, rd, Rt);
    float tMax = tG > 0.0 ? tG : tT;
    float3 T = float3(1.0, 1.0, 1.0);
    float3 L = float3(0.0, 0.0, 0.0);
    if (tMax > 0.0) L = integrateScattering(ro, rd, tMax, gFrame.sunDir.xyz, 32, T);
    if (tG > 0.0)                                               // lit ground albedo seen through the atmosphere
    {
        float3 p = ro + rd * tG;
        float3 n = normalize(p);
        L += T * transmittanceToSun(p, gFrame.sunDir.xyz) * saturate(dot(n, gFrame.sunDir.xyz)) * 0.12 / PI;
    }
    gSkyOut[gid.xy] = float4(L, 1.0);
}

[shader("compute")] [numthreads(8, 8, 2)] void aerialLUT(uint3 gid : SV_DispatchThreadID)
{
    if (gid.x >= uint(kAerialW) || gid.y >= uint(kAerialH) || gid.z >= uint(kAerialD)) return;
    float u = (float(gid.x) + 0.5) / float(kAerialW);
    float v = float(gid.y) / float(kAerialH - 1);
    float w = float(gid.z) / float(kAerialD - 1);
    float3 rd = aerialDirFromUV(u, v);
    float d = w * w * kAerialMaxDist;                           // metres (aerial-scaled for L/T, true for sunT)
    float3 ro = planetPos(float3(0.0, 0.0, 0.0));
    float3 T = float3(1.0, 1.0, 1.0);
    float3 L = float3(0.0, 0.0, 0.0);
    if (d > 0.0) L = integrateScattering(ro, rd, d * 1e-3, gFrame.sunDir.xyz, 6, T);
    gAerialOutL[gid] = float4(L * gFrame.sunColor.rgb * gFrame.sunDir.w, 1.0);
    gAerialOutT[gid] = float4(T, 1.0);
    gAerialOutS[gid] = float4(transmittanceToSun(planetPos(rd * d), gFrame.sunDir.xyz), 1.0);
}
