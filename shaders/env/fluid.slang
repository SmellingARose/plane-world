// Local FLIP/PIC fluid zone (Zhu & Bridson 2005) on the GPU: port of the Metal kernels in
// Sources/Water/WaterShaders.swift. Particles <-> staggered MAC grid; per substep: clear -> P2G -> normalise ->
// classify -> gravity + solid BCs -> divergence -> red-black SOR pressure -> projection (+ obstacle pressure
// forces) -> G2P (FLIP/PIC blend, RK2 advection, obstacle push-out).
// Differences from Swift: splats and obstacle forces accumulate in 32-bit fixed point with integer atomics
// (portable to D3D12 SM 6.0, and deterministic: integer addition is order independent); the particle density
// goes to a buffer instead of a 3D texture. Binding model: pw/compute.h; host side: src/env/src/fluid.cpp.
struct FluidParams {
    uint4 dims;       // nx, ny, nz, particle count
    float4 domain;    // h (cell size), dt, flip ratio, gravity (m/s^2, negative)
    float4 misc;      // obstacle count, density (kg/m^3), SOR omega, particles per cell
    uint4 extra;      // component (0 u, 1 v, 2 w), red-black parity, element count (clear), unused
};
ConstantBuffer<FluidParams> P : register(b0);
RWStructuredBuffer<float4> pos : register(u1);
RWStructuredBuffer<float4> pvel : register(u2);
RWStructuredBuffer<int> acc : register(u3);       // [uS vS wS][uW vW wW][dens][count][obstacle force 4x8][max speed bits]
RWStructuredBuffer<float> gvel : register(u4);    // [u v w] faces
RWStructuredBuffer<float> gold : register(u5);    // previous [u v w] (FLIP delta)
RWStructuredBuffer<uint> ctype : register(u6);    // cell type
RWStructuredBuffer<float> cells : register(u7);   // [q][div][density out]
RWStructuredBuffer<float4> obs : register(u8);    // obstacle i: center, rot (xyzw), halfExt, lin, ang

static const uint T_AIR = 0, T_FLUID = 1, T_WALL = 2, T_OBST = 3;   // obstacle i -> T_OBST + i
static const float VEL_SCALE = 65536.0;    // fixed point for velocity and weight splats
static const float FORCE_SCALE = 256.0;    // fixed point for obstacle forces (N, N m)

uint nu() { return (P.dims.x + 1) * P.dims.y * P.dims.z; }
uint nv() { return P.dims.x * (P.dims.y + 1) * P.dims.z; }
uint nw() { return P.dims.x * P.dims.y * (P.dims.z + 1); }
uint ncell() { return P.dims.x * P.dims.y * P.dims.z; }
uint faces() { return nu() + nv() + nw(); }
uint compOffset(uint c) { return c == 0 ? 0 : (c == 1 ? nu() : nu() + nv()); }
uint3 faceDims(uint c) { uint3 fd = P.dims.xyz; fd[c] += 1; return fd; }
uint sumOff(uint c) { return compOffset(c); }
uint wOff(uint c) { return faces() + compOffset(c); }
uint densOff() { return 2 * faces(); }
uint countOff() { return 2 * faces() + ncell(); }
uint forceOff() { return 2 * faces() + 2 * ncell(); }
uint speedOff() { return forceOff() + 32; }

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }
uint cellIdx(int3 c) { return uint(c.x) + P.dims.x * (uint(c.y) + P.dims.y * uint(c.z)); }
uint faceIdx(int3 c, uint3 fd) { return uint(c.x) + fd.x * (uint(c.y) + fd.y * uint(c.z)); }
float4 obsCenter(uint o) { return obs[o * 5 + 0]; }
float4 obsRot(uint o) { return obs[o * 5 + 1]; }
float4 obsHalf(uint o) { return obs[o * 5 + 2]; }
float4 obsLin(uint o) { return obs[o * 5 + 3]; }
float4 obsAng(uint o) { return obs[o * 5 + 4]; }

void splat(uint sumBase, uint wBase, bool withWeight, float3 g, uint3 fd, float val) {
    int3 b = int3(floor(g)); float3 fr = g - float3(b);
    for (int dz = 0; dz < 2; dz++)
        for (int dy = 0; dy < 2; dy++)
            for (int dx = 0; dx < 2; dx++) {
                int3 c = b + int3(dx, dy, dz);
                if (any(c < 0) || any(c >= int3(fd))) continue;
                float w = (dx != 0 ? fr.x : 1.0 - fr.x) * (dy != 0 ? fr.y : 1.0 - fr.y) * (dz != 0 ? fr.z : 1.0 - fr.z);
                uint i = faceIdx(c, fd);
                int old;
                InterlockedAdd(acc[sumBase + i], int(round(w * val * VEL_SCALE)), old);
                if (withWeight) InterlockedAdd(acc[wBase + i], int(round(w * VEL_SCALE)), old);
            }
}

float sampleFace(uint base, float3 g, uint3 fd, bool old) {
    g = clamp(g, float3(0.0), float3(fd) - 1.0001);
    int3 b = int3(floor(g)); float3 fr = g - float3(b);
    float r = 0.0;
    for (int dz = 0; dz < 2; dz++)
        for (int dy = 0; dy < 2; dy++)
            for (int dx = 0; dx < 2; dx++) {
                int3 c = min(b + int3(dx, dy, dz), int3(fd) - 1);
                float w = (dx != 0 ? fr.x : 1.0 - fr.x) * (dy != 0 ? fr.y : 1.0 - fr.y) * (dz != 0 ? fr.z : 1.0 - fr.z);
                uint i = base + faceIdx(c, fd);
                r += w * (old ? gold[i] : gvel[i]);
            }
    return r;
}
float3 sampleVel(float3 x, bool old) {
    return float3(sampleFace(compOffset(0), x - float3(0.0, 0.5, 0.5), faceDims(0), old),
                  sampleFace(compOffset(1), x - float3(0.5, 0.0, 0.5), faceDims(1), old),
                  sampleFace(compOffset(2), x - float3(0.5, 0.5, 0.0), faceDims(2), old));
}

[shader("compute")][numthreads(256, 1, 1)]
void fluidClear(uint3 g : SV_DispatchThreadID) {
    if (g.x < P.extra.z) acc[g.x] = 0;
}

[shader("compute")][numthreads(256, 1, 1)]
void fluidP2G(uint3 g : SV_DispatchThreadID) {
    uint id = g.x;
    if (id >= P.dims.w) return;
    float3 x = pos[id].xyz / P.domain.x;
    float3 v = pvel[id].xyz;
    splat(sumOff(0), wOff(0), true, x - float3(0.0, 0.5, 0.5), faceDims(0), v.x);
    splat(sumOff(1), wOff(1), true, x - float3(0.5, 0.0, 0.5), faceDims(1), v.y);
    splat(sumOff(2), wOff(2), true, x - float3(0.5, 0.5, 0.0), faceDims(2), v.z);
    splat(densOff(), 0, false, x - 0.5, P.dims.xyz, 1.0);
    int3 c = clamp(int3(floor(x)), int3(0), int3(P.dims.xyz) - 1);
    int old;
    InterlockedAdd(acc[countOff() + cellIdx(c)], 1, old);
}

// One velocity component (extra.x) per dispatch: average the splats, keep a copy for the FLIP delta.
[shader("compute")][numthreads(256, 1, 1)]
void fluidNormalize(uint3 g : SV_DispatchThreadID) {
    uint c = P.extra.x;
    uint3 fd = faceDims(c);
    uint n = fd.x * fd.y * fd.z;
    if (g.x >= n) return;
    float w = float(acc[wOff(c) + g.x]) / VEL_SCALE;
    float v = w > 1e-6 ? (float(acc[sumOff(c) + g.x]) / VEL_SCALE) / w : 0.0;
    gvel[compOffset(c) + g.x] = v;
    gold[compOffset(c) + g.x] = v;
}

[shader("compute")][numthreads(8, 8, 4)]
void fluidClassify(uint3 gid : SV_DispatchThreadID) {
    if (any(gid >= P.dims.xyz)) return;
    int3 c = int3(gid);
    uint i = cellIdx(c);
    uint t = acc[countOff() + i] > 0 ? T_FLUID : T_AIR;
    if (c.x == 0 || c.y == 0 || c.z == 0 || c.x == int(P.dims.x) - 1 || c.z == int(P.dims.z) - 1) t = T_WALL;   // top is open
    float3 p = (float3(gid) + 0.5) * P.domain.x;
    for (uint o = 0; o < uint(P.misc.x); o++) {
        float3 l = qrotInv(obsRot(o), p - obsCenter(o).xyz);
        if (all(abs(l) < obsHalf(o).xyz)) t = T_OBST + o;
    }
    ctype[i] = t;
    if (t != T_FLUID) cells[i] = 0.0;   // q
    cells[2 * ncell() + i] = (float(acc[densOff() + i]) / VEL_SCALE) / max(P.misc.w, 1.0);
}

float solidVel(uint t, float3 p, uint comp) {
    if (t < T_OBST) return 0.0;
    uint o = t - T_OBST;
    float3 v = obsLin(o).xyz + cross(obsAng(o).xyz, p - obsCenter(o).xyz);
    return v[comp];
}

[shader("compute")][numthreads(8, 8, 4)]
void fluidForces(uint3 gid : SV_DispatchThreadID) {
    uint comp = P.extra.x;
    uint3 fd = faceDims(comp);
    if (any(gid >= fd)) return;
    int3 c = int3(gid);
    uint i = compOffset(comp) + faceIdx(c, fd);
    if (c[comp] == 0 || c[comp] == int(P.dims[comp])) { gvel[i] = 0.0; return; }
    int3 cl = c; cl[comp] -= 1;
    uint tl = ctype[cellIdx(cl)], tr = ctype[cellIdx(c)];
    float3 p = float3(c) + 0.5; p[comp] -= 0.5; p *= P.domain.x;
    if (tl >= T_WALL || tr >= T_WALL) { gvel[i] = solidVel(max(tl, tr) >= T_OBST ? max(tl, tr) : T_WALL, p, comp); return; }
    if (comp == 1) gvel[i] += P.domain.w * P.domain.y;
}

[shader("compute")][numthreads(8, 8, 4)]
void fluidDivergence(uint3 gid : SV_DispatchThreadID) {
    if (any(gid >= P.dims.xyz)) return;
    int3 c = int3(gid);
    uint i = cellIdx(c);
    uint divBase = ncell();
    if (ctype[i] != T_FLUID) { cells[divBase + i] = 0.0; return; }
    uint3 fu = faceDims(0), fv = faceDims(1), fw = faceDims(2);
    uint ou = compOffset(0), ov = compOffset(1), ow = compOffset(2);
    float dv = gvel[ou + faceIdx(c + int3(1, 0, 0), fu)] - gvel[ou + faceIdx(c, fu)]
             + gvel[ov + faceIdx(c + int3(0, 1, 0), fv)] - gvel[ov + faceIdx(c, fv)]
             + gvel[ow + faceIdx(c + int3(0, 0, 1), fw)] - gvel[ow + faceIdx(c, fw)];
    cells[divBase + i] = dv / P.domain.x;
}

// Red-black SOR Gauss-Seidel for lap(q) = div(u) (q = p dt / rho), air q = 0, solid Neumann. Dispatched over
// (nx/2, ny, nz): each thread owns the cell of the requested colour (extra.y) in its x pair.
[shader("compute")][numthreads(8, 8, 4)]
void fluidPressure(uint3 gid : SV_DispatchThreadID) {
    uint x = gid.x * 2 + ((gid.y + gid.z + P.extra.y) & 1);
    if (x >= P.dims.x || gid.y >= P.dims.y || gid.z >= P.dims.z) return;
    int3 c = int3(int(x), int(gid.y), int(gid.z));
    uint i = cellIdx(c);
    if (ctype[i] != T_FLUID) return;
    float sum = 0.0, n = 0.0;
    int3 nb[6] = { int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1) };
    for (int k = 0; k < 6; k++) {
        int3 cc = c + nb[k];
        if (any(cc < 0) || any(cc >= int3(P.dims.xyz))) { n += 1.0; continue; }   // open top boundary -> air
        uint t = ctype[cellIdx(cc)];
        if (t >= T_WALL) continue;
        n += 1.0;
        if (t == T_FLUID) sum += cells[cellIdx(cc)];
    }
    if (n == 0.0) return;
    float h = P.domain.x;
    float qn = (sum - cells[ncell() + i] * h * h) / n;
    cells[i] = lerp(cells[i], qn, P.misc.z);
}

[shader("compute")][numthreads(8, 8, 4)]
void fluidProject(uint3 gid : SV_DispatchThreadID) {
    uint comp = P.extra.x;
    uint3 fd = faceDims(comp);
    if (any(gid >= fd)) return;
    int3 c = int3(gid);
    if (c[comp] == 0 || c[comp] == int(P.dims[comp])) return;
    uint i = compOffset(comp) + faceIdx(c, fd);
    int3 cl = c; cl[comp] -= 1;
    uint il = cellIdx(cl), ir = cellIdx(c);
    uint tl = ctype[il], tr = ctype[ir];
    float h = P.domain.x;
    if (tl >= T_WALL || tr >= T_WALL) {
        // Fluid pressing on an obstacle face: F = p A n, p = q rho / dt.
        bool lf = tl == T_FLUID && tr >= T_OBST, rf = tr == T_FLUID && tl >= T_OBST;
        if (lf || rf) {
            uint ot = (lf ? tr : tl) - T_OBST;
            float p = (lf ? cells[il] : cells[ir]) * P.misc.y / P.domain.y;
            float3 dir = float3(0.0); dir[comp] = lf ? 1.0 : -1.0;
            float3 F = dir * p * h * h;
            float3 ps = float3(c) + 0.5; ps[comp] -= 0.5; ps *= h;
            float3 tq = cross(ps - obsCenter(ot).xyz, F);
            uint o = forceOff() + ot * 8;
            int old;
            InterlockedAdd(acc[o + 0], int(round(F.x * FORCE_SCALE)), old);
            InterlockedAdd(acc[o + 1], int(round(F.y * FORCE_SCALE)), old);
            InterlockedAdd(acc[o + 2], int(round(F.z * FORCE_SCALE)), old);
            InterlockedAdd(acc[o + 3], int(round(tq.x * FORCE_SCALE)), old);
            InterlockedAdd(acc[o + 4], int(round(tq.y * FORCE_SCALE)), old);
            InterlockedAdd(acc[o + 5], int(round(tq.z * FORCE_SCALE)), old);
        }
        return;
    }
    if (tl != T_FLUID && tr != T_FLUID) return;
    float ql = tl == T_FLUID ? cells[il] : 0.0, qr = tr == T_FLUID ? cells[ir] : 0.0;
    gvel[i] -= (qr - ql) / h;
}

[shader("compute")][numthreads(256, 1, 1)]
void fluidG2P(uint3 g : SV_DispatchThreadID) {
    uint id = g.x;
    if (id >= P.dims.w) return;
    float h = P.domain.x, dt = P.domain.y;
    float3 xp = pos[id].xyz;
    float3 x = xp / h;
    float3 vn = sampleVel(x, false);
    float3 vold = sampleVel(x, true);
    float3 vp = pvel[id].xyz;
    float3 vflip = vp + (vn - vold);
    vp = lerp(vn, vflip, P.domain.z);
    float3 mid = xp + 0.5 * dt * vn;   // RK2 advection through the grid velocity
    float3 vm = sampleVel(mid / h, false);
    xp += dt * vm;
    float3 lo = float3(h * 1.001), hi = float3(P.dims.xyz) * h - h * 1.001;
    hi.y = float(P.dims.y) * h - h * 0.001;
    for (int k = 0; k < 3; k++) {
        if (xp[k] < lo[k]) { xp[k] = lo[k]; vp[k] = max(vp[k], 0.0); }
        if (xp[k] > hi[k]) { xp[k] = hi[k]; vp[k] = min(vp[k], 0.0); }
    }
    for (uint o = 0; o < uint(P.misc.x); o++) {
        float4 rot = obsRot(o);
        float3 cen = obsCenter(o).xyz;
        float3 l = qrotInv(rot, xp - cen);
        float3 he = obsHalf(o).xyz + h * 0.25;
        if (all(abs(l) < he)) {
            float3 pen = he - abs(l);
            int ax = pen.x < pen.y ? (pen.x < pen.z ? 0 : 2) : (pen.y < pen.z ? 1 : 2);
            l[ax] = sign(l[ax]) * he[ax];
            xp = cen + qrot(rot, l);
            float3 nW = float3(0.0); nW[ax] = sign(l[ax]); nW = qrot(rot, nW);
            float3 vs = obsLin(o).xyz + cross(obsAng(o).xyz, xp - cen);
            float rel = dot(vp - vs, nW);
            if (rel < 0.0) vp -= rel * nW;
        }
    }
    if (any(isnan(xp)) || any(isnan(vp))) { xp = float3(P.dims.xyz) * h * 0.5; vp = float3(0.0); }
    pos[id] = float4(xp, 1.0);
    pvel[id] = float4(vp, 0.0);
    int old;
    InterlockedMax(acc[speedOff()], asint(length(vp)), old);   // positive floats order like their int bits
}
