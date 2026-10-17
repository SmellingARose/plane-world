// GPU hydraulic erosion (virtual-pipe shallow water, Mei et al. 2007) + thermal weathering. Port of the Metal
// kernels in Sources/Terrain/TerrainErosion.swift (fused 3-pass hydraulic step, bit-identical in Swift to the
// original 4-pass one). Binding model: pw/compute.h (b0 constants, u1..u8 buffers). Mirror: src/env/src/erosion.cpp.
struct ErosionU {
    uint w; uint h; float cell; float dt;
    float rain; float evap; float Kc; float Ks;
    float Kd; float maxDepth; float talus; float thermal;
    uint iter; float strength; float pad0; float pad1;
};
ConstantBuffer<ErosionU> u : register(b0);
RWStructuredBuffer<float> b : register(u1);       // terrain in
RWStructuredBuffer<float> d : register(u2);       // water depth
RWStructuredBuffer<float4> flux : register(u3);   // outflow L R T B
RWStructuredBuffer<float2> vel : register(u4);
RWStructuredBuffer<float> sIn : register(u5);
RWStructuredBuffer<float> sOut : register(u6);
RWStructuredBuffer<float> moist : register(u7);
RWStructuredBuffer<float> bOut : register(u8);    // terrain out

uint eidx(int x, int y) { return uint(clamp(y, 0, int(u.h) - 1)) * u.w + uint(clamp(x, 0, int(u.w) - 1)); }
float ehash(uint a, uint c) {
    uint hh = a * 747796405u + c * 2891336453u;
    hh = ((hh >> ((hh >> 28u) + 4u)) ^ hh) * 277803737u;
    hh = (hh >> 22u) ^ hh;
    return float(hh) / 4294967295.0;
}

[shader("compute")][numthreads(16, 16, 1)]
void erodeRainFlux(uint3 g : SV_DispatchThreadID) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(x, y);
    float water = d[i];
    float H = b[i] + water;
    const float A = u.cell * u.cell * 0.25, g9 = 9.81;
    float4 f = flux[i];
    float hL = x > 0 ? b[eidx(x - 1, y)] + d[eidx(x - 1, y)] : 1e9;
    float hR = x < int(u.w) - 1 ? b[eidx(x + 1, y)] + d[eidx(x + 1, y)] : 1e9;
    float hT = y > 0 ? b[eidx(x, y - 1)] + d[eidx(x, y - 1)] : 1e9;
    float hB = y < int(u.h) - 1 ? b[eidx(x, y + 1)] + d[eidx(x, y + 1)] : 1e9;
    float k = u.dt * A * g9 / u.cell;
    f = max(float4(0.0), f * 0.995 + k * (float4(H) - float4(hL, hR, hT, hB)));
    float outF = f.x + f.y + f.z + f.w;
    float vol = water * u.cell * u.cell;
    if (outF * u.dt > vol) f *= vol / max(outF * u.dt, 1e-9);
    flux[i] = f;
}

// Fused water update + sediment exchange + evaporation (own-cell d / vel; neighbour reads of flux and b only).
[shader("compute")][numthreads(16, 16, 1)]
void erodeWaterSediment(uint3 g : SV_DispatchThreadID) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(x, y);
    float4 f = flux[i];
    float inL = x > 0 ? flux[eidx(x - 1, y)].y : 0.0;
    float inR = x < int(u.w) - 1 ? flux[eidx(x + 1, y)].x : 0.0;
    float inT = y > 0 ? flux[eidx(x, y - 1)].w : 0.0;
    float inB = y < int(u.h) - 1 ? flux[eidx(x, y + 1)].z : 0.0;
    float dV = u.dt * ((inL + inR + inT + inB) - (f.x + f.y + f.z + f.w));
    float d0 = d[i];
    float d1 = max(0.0, d0 + dV / (u.cell * u.cell));
    float dAvg = max(0.5 * (d0 + d1), 1e-3);
    float wx = 0.5 * (inL - f.x + f.y - inR), wy = 0.5 * (inT - f.z + f.w - inB);
    float2 v = float2(wx, wy) / (u.cell * dAvg);
    float vmax = 0.5 * u.cell / u.dt;
    float vl = length(v);
    if (vl > vmax) v *= vmax / vl;
    vel[i] = v;
    float r = ehash(g.x / 16u + (u.iter / 16u) * 7919u, g.y / 16u + u.iter / 16u);
    float water = d1 + u.rain * u.dt * (0.4 + 1.2 * r);
    moist[i] += min(d1, 2.0) + 0.02 * min(vl, 10.0);
    float bx = (b[eidx(x + 1, y)] - b[eidx(x - 1, y)]) / (2.0 * u.cell);
    float by = (b[eidx(x, y + 1)] - b[eidx(x, y - 1)]) / (2.0 * u.cell);
    float slope2 = bx * bx + by * by;
    float sinA = sqrt(slope2 / (1.0 + slope2));
    float depthTerm = saturate(1.0 - max(0.0, u.maxDepth - water) / u.maxDepth);
    depthTerm = sqrt(depthTerm);
    float C = u.Kc * u.strength * max(sinA, 0.03) * length(v) * depthTerm;
    float s = sIn[i];
    float bb = b[i];
    if (C > s) {
        float e = min(u.Ks * u.dt * (C - s), 0.05 * u.cell);
        bb -= e; s += e;
    } else {
        float dep = u.Kd * u.dt * (s - C);
        bb += dep; s -= dep;
    }
    bOut[i] = bb;
    sOut[i] = s;
    d[i] = water * (1.0 - u.evap * u.dt);
}

// Semi-Lagrangian sediment transport: reads slot 6 (sOut of the previous pass), writes slot 5.
[shader("compute")][numthreads(16, 16, 1)]
void erodeAdvect(uint3 g : SV_DispatchThreadID) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(x, y);
    float2 p = float2(g.xy) - vel[i] * u.dt / u.cell;
    p = clamp(p, float2(0.0), float2(float(u.w - 1), float(u.h - 1)));
    int2 p0 = int2(floor(p)); float2 fr = p - float2(p0);
    float s00 = sOut[eidx(p0.x, p0.y)], s10 = sOut[eidx(p0.x + 1, p0.y)], s01 = sOut[eidx(p0.x, p0.y + 1)], s11 = sOut[eidx(p0.x + 1, p0.y + 1)];
    sIn[i] = lerp(lerp(s00, s10, fr.x), lerp(s01, s11, fr.x), fr.y);
}

float thermalOut(int x, int y, out float total) {
    float hgt = b[eidx(x, y)], maxD = 0.0; total = 0.0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float dist = (dx != 0 && dy != 0) ? 1.41421 : 1.0;
            float diff = hgt - b[eidx(x + dx, y + dy)];
            if (diff / (dist * u.cell) > u.talus) { total += diff; maxD = max(maxD, diff); }
        }
    return maxD;
}

[shader("compute")][numthreads(16, 16, 1)]
void erodeThermal(uint3 g : SV_DispatchThreadID) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y);
    float hgt = b[eidx(x, y)];
    float myTotal; float myMax = thermalOut(x, y, myTotal);
    float moved = myTotal > 0.0 ? u.thermal * 0.5 * (myMax - u.talus * u.cell) : 0.0;
    moved = max(moved, 0.0);
    float delta = -moved;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= int(u.w) || ny >= int(u.h)) continue;
            float nTotal; float nMax = thermalOut(nx, ny, nTotal);
            if (nTotal <= 0.0) continue;
            float diff = b[eidx(nx, ny)] - hgt;
            float dist = (dx != 0 && dy != 0) ? 1.41421 : 1.0;
            if (diff / (dist * u.cell) > u.talus) {
                float nMoved = max(0.0, u.thermal * 0.5 * (nMax - u.talus * u.cell));
                delta += nMoved * diff / nTotal;
            }
        }
    bOut[uint(y) * u.w + uint(x)] = hgt + delta;
}
