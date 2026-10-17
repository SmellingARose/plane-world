// pwgpu backend tests: compute writes into a storage texture from a structured buffer and constants; a second
// kernel adds a texture read (used across the async compute queue / graphics queue fence test).
#include "common.slang"

StructuredBuffer<float4> gInput : register(t8);
Texture2D<float4> gTexIn : register(t0);
RWTexture2D<float4> gTexOut : register(u8);
struct TestParams { float4 scale; };
ConstantBuffer<TestParams> gTest : register(b1);

[shader("compute")] [numthreads(8, 8, 1)] void fillKernel(uint3 gid : SV_DispatchThreadID)
{
    uint w, h;
    gTexOut.GetDimensions(w, h);
    if (gid.x >= w || gid.y >= h) return;
    float4 v = gInput[(gid.y * w + gid.x) % 64];
    gTexOut[gid.xy] = v * gTest.scale + float4(float(gid.x), float(gid.y), 0, 0) / 255.0;
}

[shader("compute")] [numthreads(8, 8, 1)] void addKernel(uint3 gid : SV_DispatchThreadID)
{
    uint w, h;
    gTexOut.GetDimensions(w, h);
    if (gid.x >= w || gid.y >= h) return;
    gTexOut[gid.xy] = gTexIn.Load(int3(gid.xy, 0)) + gTest.scale;
}

// Instanced triangle with vertex pulling + depth test: checks graphics pipelines, index buffers and depth.
struct TriOut { float4 pos : SV_Position; nointerpolation float4 color : COLOR0; };
[shader("vertex")] TriOut triVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    float4 p = gInput[vid];
    TriOut o;
    o.pos = float4(p.xy + float2(float(iid) * 0.5, 0.0), p.z, 1.0);
    o.color = gInput[8 + iid];
    return o;
}
[shader("fragment")] float4 triFragment(TriOut i) : SV_Target { return i.color; }
