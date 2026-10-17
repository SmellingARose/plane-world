// CDLOD terrain (Strugar 2009): every selected node (pw::terrain::selectLOD) is one instance of the same
// N x N grid patch; vertices morph to the parent grid with distance so LOD transitions are seamless. Heights come
// from the heightfield texture with the same outside-falloff formula as HeightField::sampleHeight (CPU), so
// physics and pixels agree. Materials: splat weights (grass, rock, sand/dirt, snow) with procedural detail.
#include "env_common.slang"

struct TerrainDraw {
    float4 field;        // camera-relative world xz of sample (0,0), spacing (m), 1 / spacing
    float4 dims;         // width, height (samples), base level, falloff (m)
    float4 grid;         // patch resolution (quads), 1 / resolution, morph detail, unused
    float4 tint;         // global colour multiplier rgb, wetness boost
};
ConstantBuffer<TerrainDraw> draw : register(b1);
struct TerrainNodeGPU { float2 origin; float size; float level; float2 morph; float2 heightRange; };   // = pw::terrain::TerrainNodeGPU
StructuredBuffer<TerrainNodeGPU> nodes : register(t8);
Texture2D<float> heights : register(t1);      // composite heights (m)
Texture2D<float4> splat : register(t2);       // unorm weights grass, rock, sand/dirt, snow
Texture2D<float> moisture : register(t3);

float sampleHeight(float2 xzRel) {
    float2 uv = (xzRel - draw.field.xy) * draw.field.w;          // sample units
    float2 maxUV = draw.dims.xy - 1.0;
    float2 c = clamp(uv, 0.0, maxUV);
    float h = heights.SampleLevel(linearClamp, (c + 0.5) / draw.dims.xy, 0);
    float2 d = max(-uv, 0.0) + max(uv - maxUV, 0.0);
    if (d.x == 0.0 && d.y == 0.0) return h;
    float t = smoothstep(0.0, draw.dims.w, length(d) * draw.field.z);
    return h + (draw.dims.z - h) * t;
}

struct VSOut {
    float4 pos : SV_Position;
    float3 rel : TEXCOORD0;      // camera-relative world position
    float2 uv : TEXCOORD1;       // heightfield texture uv
    float morph : TEXCOORD2;
};

[shader("vertex")]
VSOut terrainVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    TerrainNodeGPU n = nodes[iid];
    uint res = uint(draw.grid.x), row = res + 1;
    float2 g = float2(float(vid % row), float(vid / row));       // grid vertex (drawn as an indexed res x res patch)
    float2 xz = n.origin + g * (n.size * draw.grid.y);
    float hApprox = sampleHeight(xz);
    float dist = length(float3(xz.x, hApprox - frame.cameraPos.y, xz.y));   // camera at the origin
    float k = saturate((dist - n.morph.x) / max(n.morph.y - n.morph.x, 1e-3));
    // morph odd grid vertices onto the parent grid (CDLOD morphVertex)
    float2 frac2 = frac(g * 0.5) * 2.0;
    g -= frac2 * k;
    xz = n.origin + g * (n.size * draw.grid.y);
    float h = sampleHeight(xz);
    VSOut o;
    o.rel = float3(xz.x, h - frame.cameraPos.y, xz.y);
    o.pos = mul(float4(o.rel, 1.0), frame.viewProj);
    o.uv = ((xz - draw.field.xy) * draw.field.w + 0.5) / draw.dims.xy;
    o.morph = k;
    return o;
}

float3 terrainNormal(float2 xz) {
    float e = draw.field.z;
    float hx = sampleHeight(xz + float2(e, 0)) - sampleHeight(xz - float2(e, 0));
    float hz = sampleHeight(xz + float2(0, e)) - sampleHeight(xz - float2(0, e));
    return normalize(float3(-hx, 2.0 * e, -hz));
}

[shader("fragment")]
float4 terrainPS(VSOut i) : SV_Target {
    float2 xzWorld = i.rel.xz + frame.cameraPos.xz;
    float3 n = terrainNormal(i.rel.xz);
    float4 w = splat.Sample(linearClamp, i.uv);
    w /= max(w.x + w.y + w.z + w.w, 1e-3);
    float wet = moisture.Sample(linearClamp, i.uv);
    float detail = hash12(floor(xzWorld * 2.0)) * 0.08 - 0.04;
    float macro = hash12(floor(xzWorld / 37.0)) * 0.12 - 0.06;
    float3 grass = lerp(float3(0.20, 0.27, 0.09), float3(0.13, 0.22, 0.07), wet) * (1.0 + detail + macro);
    float3 rock = float3(0.36, 0.34, 0.31) * (1.0 + detail * 1.5);
    float3 sand = lerp(float3(0.62, 0.56, 0.42), float3(0.36, 0.30, 0.22), wet);
    float3 snow = float3(0.92, 0.94, 0.97);
    float3 albedo = (grass * w.x + rock * w.y + sand * w.z + snow * w.w) * draw.tint.rgb;
    float3 c = lambertSky(albedo, n, 1.0);
    return float4(applyFog(c, i.rel), 1.0);
}
