// Tessendorf FFT ocean on the GPU: port of the fused path in Sources/Water/WaterShaders.swift (oceanSpecRowFFT +
// oceanColFFTFinalize). 2 dispatches: A evaluates h(k,t) and the 7 derived spectra for one row straight into
// groupshared memory (bit-reversed) and inverse-FFTs it; B inverse-FFTs one column and finalizes each texel
// (displacement, derivatives, Jacobian foam). Fixed 256-thread groups handle any power-of-two N <= 512.
// Binding model: pw/compute.h. CPU mirror (and the reference the GPU result is tested against): src/env/src/ocean.cpp.
static const float PI = 3.14159265358979323846;
static const uint TG = 256;
struct OceanParams {
    uint N; uint logN; uint cascades; uint pad0;
    float4 L;
    float time; float choppy; float dt; float foamDecay;
    float foamThreshold; float foamGain; float pad1; float pad2;
};
ConstantBuffer<OceanParams> P : register(b0);
RWStructuredBuffer<float4> h0 : register(u1);      // h0(k), conj(h0(-k))
RWStructuredBuffer<float> omega : register(u2);
RWStructuredBuffer<float2> spec : register(u3);    // [c][y][x][4] complex
RWStructuredBuffer<float2> tw : register(u4);      // exp(i 2 pi k / N), k < N/2
RWStructuredBuffer<float> foam : register(u5);
RWStructuredBuffer<float4> outDisp : register(u6); // Dx, h, Dz, J
RWStructuredBuffer<float4> outDeriv : register(u7);// dh/dx, dh/dz, dDx/dx, dDz/dz

groupshared float2 buf[512 * 4];

float2 cmul(float2 a, float2 c) { return float2(a.x * c.x - a.y * c.y, a.x * c.y + a.y * c.x); }
float2 cpack(float2 a, float2 c) { return float2(a.x - c.y, a.y + c.x); }   // A + iB for two Hermitian spectra

void specAt(uint x, uint y, uint c, out float2 o0, out float2 o1, out float2 o2, out float2 o3) {
    uint N = P.N;
    uint idx = (c * N + y) * N + x;
    float L = P.L[c];
    float2 k = 2.0 * PI * (float2(float(x), float(y)) - float(N / 2)) / L;
    float kl = length(k);
    float2 kn = kl > 1e-6 ? k / kl : float2(0.0);
    float4 hv = h0[idx];
    float ph = omega[idx] * P.time;
    float cs = cos(ph), sn = sin(ph);
    float2 hh = cmul(hv.xy, float2(cs, sn)) + cmul(hv.zw, float2(cs, -sn));
    float2 ih = float2(-hh.y, hh.x);
    float2 hDx = -ih * kn.x, hDz = -ih * kn.y, hHx = ih * k.x, hHz = ih * k.y;
    float inv = kl > 1e-6 ? 1.0 / kl : 0.0;
    o0 = cpack(hh, hDx);
    o1 = cpack(hDz, hHx);
    o2 = cpack(hHz, hh * (k.x * k.x * inv));
    o3 = cpack(hh * (k.y * k.y * inv), hh * (k.x * k.y * inv));
}

void butterflies(uint N, uint logN, uint t) {
    for (uint s = 1; s <= logN; s++) {
        uint m = 1u << s, hm = m >> 1;
        for (uint bfly = t; bfly < N / 2; bfly += TG) {
            uint j = bfly & (hm - 1);
            uint i0 = (bfly >> (s - 1)) * m + j, i1 = i0 + hm;
            float2 w = tw[j << (logN - s)];
            for (uint f = 0; f < 4; f++) {
                float2 a = buf[i0 * 4 + f], c = cmul(buf[i1 * 4 + f], w);
                buf[i0 * 4 + f] = a + c; buf[i1 * 4 + f] = a - c;
            }
        }
        GroupMemoryBarrierWithGroupSync();
    }
}

uint bitrev(uint e, uint logN) { return reversebits(e) >> (32 - logN); }

[shader("compute")][numthreads(256, 1, 1)]
void oceanSpecRowFFT(uint3 tg : SV_GroupID, uint t : SV_GroupIndex) {
    uint N = P.N, logN = P.logN, y = tg.x, c = tg.y;
    for (uint e = t; e < N; e += TG) {
        float2 v0, v1, v2, v3;
        specAt(e, y, c, v0, v1, v2, v3);
        uint r = bitrev(e, logN);
        buf[r * 4 + 0] = v0; buf[r * 4 + 1] = v1; buf[r * 4 + 2] = v2; buf[r * 4 + 3] = v3;
    }
    GroupMemoryBarrierWithGroupSync();
    butterflies(N, logN, t);
    for (uint e = t; e < N; e += TG) {
        uint i = (c * N + y) * N + e;
        for (uint f = 0; f < 4; f++) spec[i * 4 + f] = buf[e * 4 + f];
    }
}

[shader("compute")][numthreads(256, 1, 1)]
void oceanColFFTFinalize(uint3 tg : SV_GroupID, uint t : SV_GroupIndex) {
    uint N = P.N, logN = P.logN, x = tg.x, c = tg.y;
    for (uint e = t; e < N; e += TG) {
        uint i = (c * N + e) * N + x;
        uint r = bitrev(e, logN);
        for (uint f = 0; f < 4; f++) buf[r * 4 + f] = spec[i * 4 + f];
    }
    GroupMemoryBarrierWithGroupSync();
    butterflies(N, logN, t);
    float decay = exp(-P.dt / max(P.foamDecay, 1e-3));
    float lam = P.choppy;
    for (uint y = t; y < N; y += TG) {
        uint idx = (c * N + y) * N + x;
        float sg = ((x + y) & 1) != 0 ? -1.0 : 1.0;
        float2 v0 = buf[y * 4 + 0] * sg, v1 = buf[y * 4 + 1] * sg, v2 = buf[y * 4 + 2] * sg, v3 = buf[y * 4 + 3] * sg;
        float hgt = v0.x, dx = v0.y * lam, dz = v1.x * lam, hx = v1.y, hz = v2.x;
        float dxx = v2.y * lam, dzz = v3.x * lam, dxz = v3.y * lam;
        float J = (1.0 + dxx) * (1.0 + dzz) - dxz * dxz;
        float fo = max(foam[idx] * decay, saturate((P.foamThreshold - J) * P.foamGain));
        foam[idx] = fo;
        outDisp[idx] = float4(dx, hgt, dz, J);
        outDeriv[idx] = float4(hx, hz, dxx, dzz);
    }
}
