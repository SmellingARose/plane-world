// Viewport background pass (used by the pwgpu smoke test): fullscreen triangle, clear colour blended into a soft
// sky gradient with a horizon line. Parameters arrive as constant buffer b1.
struct ViewParams
{
    float4 clearColor;   // linear RGBA of the empty viewport
    float4 skyColor;     // zenith tint
    float  time;         // seconds, for a gentle animated shimmer
    float  aspect;
    float  horizon;      // 0..1 from the bottom
    float  pad;
};
ConstantBuffer<ViewParams> gParams : register(b1);

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

[shader("vertex")] VSOut vsMain(uint vid : SV_VertexID)
{
    VSOut o;
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    o.uv = float2(p.x, 1.0 - p.y);
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

[shader("fragment")] float4 psMain(VSOut i) : SV_Target
{
    float y = 1.0 - i.uv.y;                       // 0 bottom, 1 top
    float h = gParams.horizon;
    float above = smoothstep(h, 1.0, y);
    float3 c = lerp(gParams.clearColor.rgb, gParams.skyColor.rgb, above);
    float line = exp(-abs(y - h) * 220.0) * (0.10 + 0.04 * sin(gParams.time * 1.3));
    c += line;
    return float4(c, 1.0);
}
