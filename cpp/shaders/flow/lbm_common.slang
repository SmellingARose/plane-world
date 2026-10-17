// Lattice-Boltzmann CFD kernels (port of Sources/Flow/LBMShaders.swift, the Metal source of the Swift solver).
// Included by lbm19.slang / lbm27.slang, which define Q (velocity set) before including this file.
//
// Layout: populations SoA float, f[i*N + cell]; cell = x + nx*(y + ny*z). Per LBM step:
//   collide (in place f -> f*, writes macroscopic u, rho)  then  stream (pull f* -> f_next, walls, momentum exchange).
// Lattice units throughout (dx = dt = 1, rho0 = 1, cs^2 = 1/3).
//
// Binding model (pw/compute.h): b0 = per-dispatch constants, u1..u8 = storage buffers. Slots are shared by role:
//   u1 scene  float4: [0..9] params, [10..57] rotors (3 float4 each), parts (7 float4 each), sample points
//   u2 fA     float : populations (collide/stream source; init/rescale target) | voxelize: part SDF grid data
//   u3 fB     float : stream destination
//   u4 mOut   float4: macro (u, rho; rho < 0 = solid) written by collide | particles: tracer positions
//   u5 mIn    float4: previous macro (outlet / WALE / slice / particles / mass / sample)
//   u6 geo    float2: (signed distance in cells, part id bits: -1 none, -2 ground, k = part slot)
//   u7 links  uint  : wall crossings, two 16-bit link codes per uint ([i/2]*N + cell) | slice: RGBA8 pixels
//   u8 red    uint  : reductions: [0] max lattice Mach bits, [1] NaN flag, [2] fluid cells, [4..5] sum rho,
//                     [6] slice range bits, [8 + 12k] force/torque of part k (6 x 64-bit fixed point), then
//                     4 float bits per sample point
// Differences from the Metal source: float atomics become 64-bit fixed-point integer atomics after a wave
// (SIMD-group) reduction (D3D12 SM 6.0 has no float atomics; Metal only has a weak compare-exchange), part ids and distances share one buffer, links are packed in pairs.

struct Dispatch {
    int4 i;      // kernel-specific integers
    float4 f;    // kernel-specific floats
};
ConstantBuffer<Dispatch> D : register(b0);

RWStructuredBuffer<float4> scene : register(u1);
RWStructuredBuffer<float> fA : register(u2);
RWStructuredBuffer<float> fB : register(u3);
RWStructuredBuffer<float4> mOut : register(u4);
RWStructuredBuffer<float4> mIn : register(u5);
RWStructuredBuffer<float2> geo : register(u6);
RWStructuredBuffer<uint> links : register(u7);
RWStructuredBuffer<uint> red : register(u8);

#if Q == 19
static const int3 C[19] = {
    int3(0, 0, 0),
    int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1),
    int3(1, 1, 0), int3(-1, -1, 0), int3(1, -1, 0), int3(-1, 1, 0), int3(1, 0, 1), int3(-1, 0, -1),
    int3(1, 0, -1), int3(-1, 0, 1), int3(0, 1, 1), int3(0, -1, -1), int3(0, 1, -1), int3(0, -1, 1) };
static const float W[19] = {
    1.0 / 3.0,
    1.0 / 18.0, 1.0 / 18.0, 1.0 / 18.0, 1.0 / 18.0, 1.0 / 18.0, 1.0 / 18.0,
    1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0,
    1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0 };
#elif Q == 27
static const int3 C[27] = {
    int3(0, 0, 0),
    int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1),
    int3(1, 1, 0), int3(-1, -1, 0), int3(1, -1, 0), int3(-1, 1, 0), int3(1, 0, 1), int3(-1, 0, -1),
    int3(1, 0, -1), int3(-1, 0, 1), int3(0, 1, 1), int3(0, -1, -1), int3(0, 1, -1), int3(0, -1, 1),
    int3(1, 1, 1), int3(-1, -1, -1), int3(1, 1, -1), int3(-1, -1, 1), int3(1, -1, 1), int3(-1, 1, -1),
    int3(-1, 1, 1), int3(1, -1, -1) };
static const float W[27] = {
    8.0 / 27.0,
    2.0 / 27.0, 2.0 / 27.0, 2.0 / 27.0, 2.0 / 27.0, 2.0 / 27.0, 2.0 / 27.0,
    1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0,
    1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0, 1.0 / 54.0,
    1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0, 1.0 / 216.0 };
#else
#error "define Q (19 or 27) before including lbm_common.slang"
#endif
int OPP(int i) { return i == 0 ? 0 : ((i & 1) != 0 ? i + 1 : i - 1); }

// ---------------------------------------------------------------- params (scene[0..9])
struct Params {
    int4 dim;        // nx, ny, nz, N
    int4 mode;       // collision (0 bgk, 1 trt/"mrt", 2 regularized), turbulence (0 none, 1 smag, 2 wale), interpolatedBB, rotorCount
    int4 mode2;      // partCount, spongeCells, hasGround, step
    float4 relax;    // omega0, tau0, Smagorinsky Cs, WALE Cw
    float4 uFar;     // far-field velocity (lattice), w = inflow face mask
    float4 accel;    // uniform frame acceleration (lattice / step), w = Smagorinsky wall-damping length (cells, 0 = off)
    float4 center;   // CoM in grid coordinates (cells), w = dx (m)
    float4 ground;   // x = ground plane y in grid coordinates, yzw = ground velocity (lattice)
    float4 misc;     // x sponge strength, y accuracy flags (bit 0: inflate thin parts only, bit 1: refined crossings), z dt (s), w unused
    int4 layout;     // x part base (float4 index), y sample base, z sample count, w reduction offset of the samples
};
static const int ROTOR_BASE = 10;
static const int PART_STRIDE = 7;

Params loadParams() {
    Params p;
    p.dim = asint(scene[0]); p.mode = asint(scene[1]); p.mode2 = asint(scene[2]);
    p.relax = scene[3]; p.uFar = scene[4]; p.accel = scene[5]; p.center = scene[6]; p.ground = scene[7]; p.misc = scene[8];
    p.layout = asint(scene[9]);
    return p;
}

struct GPart {
    float4 rot;      // world-from-part quaternion (xyz, w)
    float4 pos;      // part origin relative to the CoM (m); w = bound radius (m)
    float4 linVel;   // lattice units, relative to the domain frame
    float4 angVel;   // rad per lattice step (world axes); w = extra inflation (m)
    int4 grid;       // nx, ny, nz, offset into grid data
    float4 origin;   // part-local corner of the sdf grid (m), w = h (m)
    int4 flags;      // x thin, y disabled
};
GPart loadPart(Params P, int k) {
    int b = P.layout.x + k * PART_STRIDE;
    GPart g;
    g.rot = scene[b]; g.pos = scene[b + 1]; g.linVel = scene[b + 2]; g.angVel = scene[b + 3];
    g.grid = asint(scene[b + 4]); g.origin = scene[b + 5]; g.flags = asint(scene[b + 6]);
    return g;
}

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }
uint cellIndex(int3 g, int4 dim) { return uint(g.x + dim.x * (g.y + dim.y * g.z)); }
bool inside(int3 g, int4 dim) { return all(g >= 0) && g.x < dim.x && g.y < dim.y && g.z < dim.z; }

float feq(int i, float rho, float3 u) {
    float cu = dot(float3(C[i]), u);
    return W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * dot(u, u));
}

uint linkCode(int i, uint idx, int N) {
    uint w = links[uint(i >> 1) * uint(N) + idx];
    return (i & 1) != 0 ? (w >> 16) : (w & 0xFFFFu);
}

/// 64-bit two's-complement fixed point (2^-24 resolution) accumulated with 32-bit integer atomics: lo word, then the
/// hi word plus the carry out of lo. Integer addition is order independent, so the sums are deterministic.
static const float FIXED_SCALE = 16777216.0;
void atomicAddFixed(uint i, float x) {
    float v = round(x * FIXED_SCALE);
    if (v == 0.0 || isnan(v)) return;
    float hiF = floor(v / 4294967296.0);
    float loF = v - hiF * 4294967296.0;     // exact: both terms are multiples of v's ulp
    uint lo = uint(loF), hi = uint(int(hiF));
    uint old;
    InterlockedAdd(red[i], lo, old);
    uint carry = (old + lo < old) ? 1u : 0u;
    if (hi + carry != 0u) { uint o2; InterlockedAdd(red[i + 1], hi + carry, o2); }
}

// ---------------------------------------------------------------- geometry
float sampleGrid(GPart p, float3 l) {   // fA = grid data in lbmVoxelize
    float h = p.origin.w;
    float3 u = (l - p.origin.xyz) / h - 0.5;
    float3 n = float3(p.grid.xyz);
    if (any(u < 0.0) || any(u > n - 1.0)) {
        float3 lo = p.origin.xyz, hi = p.origin.xyz + n * h;
        float3 dd = max(max(lo - l, l - hi), 0.0);
        return length(dd) + 2.0 * h;
    }
    int3 i0 = min(int3(floor(u)), p.grid.xyz - 2);
    float3 fr = u - float3(i0);
    int nx = p.grid.x, ny = p.grid.y; int off = p.grid.w;
    float g000 = fA[off + (i0.x) + nx * ((i0.y) + ny * (i0.z))], g100 = fA[off + (i0.x + 1) + nx * ((i0.y) + ny * (i0.z))];
    float g010 = fA[off + (i0.x) + nx * ((i0.y + 1) + ny * (i0.z))], g110 = fA[off + (i0.x + 1) + nx * ((i0.y + 1) + ny * (i0.z))];
    float g001 = fA[off + (i0.x) + nx * ((i0.y) + ny * (i0.z + 1))], g101 = fA[off + (i0.x + 1) + nx * ((i0.y) + ny * (i0.z + 1))];
    float g011 = fA[off + (i0.x) + nx * ((i0.y + 1) + ny * (i0.z + 1))], g111 = fA[off + (i0.x + 1) + nx * ((i0.y + 1) + ny * (i0.z + 1))];
    float c00 = lerp(g000, g100, fr.x), c10 = lerp(g010, g110, fr.x);
    float c01 = lerp(g001, g101, fr.x), c11 = lerp(g011, g111, fr.x);
    return lerp(lerp(c00, c10, fr.y), lerp(c01, c11, fr.y), fr.z);
}

/// Wall velocity (lattice) of the owner of a wall point g (part slot pid; -2 = ground).
float3 wallVelocity(Params P, int pid, float3 g) {
    if (pid == -2) return P.ground.yzw;
    if (pid < 0) return float3(0.0, 0.0, 0.0);
    GPart p = loadPart(P, pid);
    float3 r = g - (P.center.xyz + p.pos.xyz / P.center.w);
    return p.linVel.xyz + cross(p.angVel.xyz, r);
}

/// Signed distance (m) of the scene at a point relative to the CoM; `part` = owner slot (-2 ground).
/// Swift inflates every part by 0.3 of its sdf cell so zero-thickness sheets have a finite core; with accuracy flag
/// bit 0 only thin parts (no interior cell) are inflated, so closed bodies keep their true volume.
float sceneSDF(Params P, float3 pm, out int part) {
    float dx = P.center.w;
    float best = 1e9; part = -1;
    bool thinOnly = (asint(P.misc.y) & 1) != 0;
    for (int k = 0; k < P.mode2.x; k++) {
        GPart p = loadPart(P, k);
        if (p.flags.y != 0) continue;
        float3 d = pm - p.pos.xyz;
        if (length(d) > p.pos.w + 2.0 * dx) continue;
        float inflate = (!thinOnly || p.flags.x != 0) ? 0.3 * p.origin.w : 0.0;
        float s = sampleGrid(p, qrotInv(p.rot, d)) - inflate - p.angVel.w;
        if (s < best) { best = s; part = k; }
    }
    if (P.mode2.z != 0) {
        float sg = pm.y - (P.ground.x - P.center.y) * dx;
        if (sg < best) { best = sg; part = -2; }
    }
    return best;
}

// ---------------------------------------------------------------- voxelise
/// Per node: signed distance (cells) and nearest part; for near-wall fluid nodes the wall crossing of every link,
/// sampled at 1/8 steps along x -> x - c_i (sheets thinner than a cell still cut the link). Link code: 0 = no wall,
/// else low byte q*255 (1..255), high byte part slot + 1 (255 = ground). With accuracy flag bit 1 the bracketing
/// 1/8 interval is refined by two secant (regula falsi) iterations instead of one linear interpolation.
[shader("compute")][numthreads(32, 2, 2)]
void lbmVoxelize(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int3 g = int3(gid);
    if (!inside(g, P.dim)) return;
    int N = P.dim.w;
    uint idx = cellIndex(g, P.dim);
    float dx = P.center.w;
    float3 pm = (float3(g) - P.center.xyz) * dx;
    int bp;
    float s0 = sceneSDF(P, pm, bp);
    geo[idx] = float2(s0 / dx, asfloat(bp));
    bool nearWall = s0 > 0.0 && s0 < 2.0 * dx;
    bool refine = (asint(P.misc.y) & 2) != 0;
    uint packed = 0;
    for (int i = 0; i < Q; i++) {
        uint code = 0;
        if (nearWall && i > 0) {
            float3 stepv = -float3(C[i]) * dx;
            float sa = s0, ta = 0.0;
            for (int k = 1; k <= 8; k++) {
                float t = float(k) / 8.0;
                int pk;
                float sb = sceneSDF(P, pm + t * stepv, pk);
                if (sb <= 0.0) {
                    float q = ta + (t - ta) * sa / max(sa - sb, 1e-9);
                    if (refine) {
                        float lo = ta, hi = t, flo = sa, fhi = sb;
                        for (int r = 0; r < 2; r++) {
                            int pr;
                            float fq = sceneSDF(P, pm + q * stepv, pr);
                            if (fq > 0.0) { lo = q; flo = fq; } else { hi = q; fhi = fq; }
                            q = lo + (hi - lo) * flo / max(flo - fhi, 1e-9);
                        }
                    }
                    if (P.mode.z == 0) q = 0.5;
                    uint qq = uint(clamp(q * 255.0 + 0.5, 1.0, 255.0));
                    uint pc = pk == -2 ? 255u : uint(min(pk + 1, 254));
                    code = qq | (pc << 8);
                    break;
                }
                sa = sb; ta = t;
            }
        }
        if ((i & 1) == 0) { packed = code; if (i == Q - 1) links[uint(i >> 1) * uint(N) + idx] = packed; }
        else links[uint(i >> 1) * uint(N) + idx] = packed | (code << 16);
    }
}

// ---------------------------------------------------------------- init / rescale / clear
[shader("compute")][numthreads(128, 1, 1)]
void lbmInit(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int c = int(gid.x);
    if (c >= P.dim.w) return;
    for (int i = 0; i < Q; i++) fA[i * P.dim.w + c] = feq(i, 1.0, P.uFar.xyz);
}

/// Changes the lattice time step by factor k (u -> k u): f = feq(rho, k u) + k (f - feq(rho, u)). k = D.f.x.
[shader("compute")][numthreads(128, 1, 1)]
void lbmRescale(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int c = int(gid.x);
    if (c >= P.dim.w) return;
    int N = P.dim.w;
    float k = D.f.x;
    float fl[Q]; float rho = 0.0; float3 m = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < Q; i++) { fl[i] = fA[i * N + c]; rho += fl[i]; m += fl[i] * float3(C[i]); }
    float3 u = m / max(rho, 1e-6);
    for (int i = 0; i < Q; i++) { float e = feq(i, rho, u); fA[i * N + c] = feq(i, rho, k * u) + k * (fl[i] - e); }
}

/// Zeroes red[0 .. D.i.x) (reductions of one update).
[shader("compute")][numthreads(128, 1, 1)]
void lbmClear(uint3 gid : SV_DispatchThreadID) {
    if (int(gid.x) < D.i.x) red[gid.x] = 0u;
}

// ---------------------------------------------------------------- collide
[shader("compute")][numthreads(32, 2, 2)]
void lbmCollide(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int3 g = int3(gid);
    if (!inside(g, P.dim)) return;
    int N = P.dim.w;
    uint idx = cellIndex(g, P.dim);
    float2 gc = geo[idx];
    if (gc.x <= 0.0) {
        // Solid: hold equilibrium at the wall velocity so freshly uncovered cells start sensibly.
        float3 uw = wallVelocity(P, asint(gc.y), float3(g));
        for (int i = 0; i < Q; i++) fA[i * N + idx] = feq(i, 1.0, uw);
        mOut[idx] = float4(uw, -1.0);
        return;
    }
    // Far field: inflow faces (bit set in uFar.w) are Dirichlet u_inf with a velocity sponge; all other faces are open
    // (zero-gradient) with a pressure-only sponge, so circulation / downwash can leave the domain.
    int mask = int(P.uFar.w);
    int dIn = 1 << 20, dOut = 1 << 20;
    for (int a = 0; a < 3; a++) {
        int lo = g[a], hi = P.dim[a] - 1 - g[a];
        if ((mask & (1 << (2 * a))) != 0) dIn = min(dIn, lo); else dOut = min(dOut, lo);
        if ((mask & (1 << (2 * a + 1))) != 0) dIn = min(dIn, hi); else dOut = min(dOut, hi);
    }
    float3 uF = P.uFar.xyz;
    if (dIn == 0) {
        for (int i = 0; i < Q; i++) fA[i * N + idx] = feq(i, 1.0, uF);
        mOut[idx] = float4(uF, 1.0);
        return;
    }
    if (dOut == 0) {   // open face: equilibrium at rho0 and the inward neighbour's velocity (previous step)
        int3 gi = clamp(g, int3(1, 1, 1), P.dim.xyz - 2);
        float4 mi = mIn[cellIndex(gi, P.dim)];
        float3 uo = mi.w > 0.0 ? mi.xyz : uF;
        float lu = length(uo); if (lu > 0.3) uo *= 0.3 / lu;
        for (int i = 0; i < Q; i++) fA[i * N + idx] = feq(i, 1.0, uo);
        mOut[idx] = float4(uo, 1.0);
        return;
    }
    float fl[Q];
    float rho = 0.0; float3 m = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < Q; i++) { fl[i] = fA[i * N + idx]; rho += fl[i]; m += fl[i] * float3(C[i]); }
    // Body force: frame acceleration + actuator disks (thrust + swirl).
    float3 F = rho * P.accel.xyz;
    float3 x = float3(g);
    for (int r = 0; r < P.mode.w; r++) {
        float4 c = scene[ROTOR_BASE + 3 * r], ax = scene[ROTOR_BASE + 3 * r + 1], sw = scene[ROTOR_BASE + 3 * r + 2];
        float3 d = x - c.xyz; float a = dot(d, ax.xyz);
        float hw = 1.0 - abs(a) / sw.y;                        // axial hat, sum over cells = 1
        if (hw <= 0.0) continue;
        float3 rr = d - a * ax.xyz; float rad = length(rr);
        if (rad > c.w) continue;
        F += -ax.xyz * (ax.w * hw);                            // thrust reaction on the air
        if (rad > 1e-4) F += normalize(cross(ax.xyz, rr)) * (sw.x * rad * hw);   // swirl
    }
    float3 u = (m + 0.5 * F) / max(rho, 1e-6);
    float tau0 = P.relax.y;
    // Non-equilibrium stress Pi_neq (xx yy zz xy xz yz).
    float fe[Q]; float pxx = 0.0, pyy = 0.0, pzz = 0.0, pxy = 0.0, pxz = 0.0, pyz = 0.0;
    for (int i = 0; i < Q; i++) {
        fe[i] = feq(i, rho, u);
        float n = fl[i] - fe[i]; float3 cc = float3(C[i]);
        pxx += n * cc.x * cc.x; pyy += n * cc.y * cc.y; pzz += n * cc.z * cc.z;
        pxy += n * cc.x * cc.y; pxz += n * cc.x * cc.z; pyz += n * cc.y * cc.z;
    }
    float tau = tau0;
    if (P.mode.y == 1) {   // Smagorinsky (Hou et al. 1996), Delta = 1 cell, van Driest-style wall damping
        float Qn = sqrt(pxx * pxx + pyy * pyy + pzz * pzz + 2.0 * (pxy * pxy + pxz * pxz + pyz * pyz));
        float cs2 = P.relax.z * P.relax.z;
        float dw = gc.x;
        float damp = P.accel.w > 0.0 ? 1.0 - exp(-max(dw, 0.0) / P.accel.w) : 1.0;
        cs2 *= damp * damp;
        tau = 0.5 * (tau0 + sqrt(tau0 * tau0 + 18.0 * 1.41421356 * cs2 * Qn / max(rho, 1e-6)));
    } else if (P.mode.y == 2) {   // WALE (Nicoud & Ducros 1999) from the previous step's velocity field
        float G[3][3];   // G[a][b] = du_a / dx_b
        for (int b = 0; b < 3; b++) {
            int3 e = int3(b == 0 ? 1 : 0, b == 1 ? 1 : 0, b == 2 ? 1 : 0);
            int3 gp = clamp(g + e, int3(0, 0, 0), P.dim.xyz - 1), gm = clamp(g - e, int3(0, 0, 0), P.dim.xyz - 1);
            float3 du = 0.5 * (mIn[cellIndex(gp, P.dim)].xyz - mIn[cellIndex(gm, P.dim)].xyz);
            G[0][b] = du.x; G[1][b] = du.y; G[2][b] = du.z;
        }
        float g2[3][3];
        for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) g2[a][b] = G[a][0] * G[0][b] + G[a][1] * G[1][b] + G[a][2] * G[2][b];
        float tr = (g2[0][0] + g2[1][1] + g2[2][2]) / 3.0;
        float SS = 0.0, SdSd = 0.0;
        for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) {
            float S = 0.5 * (G[a][b] + G[b][a]);
            float Sd = 0.5 * (g2[a][b] + g2[b][a]) - (a == b ? tr : 0.0);
            SS += S * S; SdSd += Sd * Sd;
        }
        float cw2 = P.relax.w * P.relax.w;
        float nut = cw2 * pow(SdSd, 1.5) / (pow(SS, 2.5) + pow(SdSd, 1.25) + 1e-20);
        tau = tau0 + 3.0 * nut;
    }
    tau = max(tau, 0.5005);
    float om = 1.0 / tau;
    // Sponge toward the far field near the outer faces.
    float sig = 0.0, sigP = 0.0;
    if (dIn < P.mode2.y) { float s = 1.0 - float(dIn) / float(P.mode2.y); sig = P.misc.x * s * s; }
    if (dOut < P.mode2.y) { float s = 1.0 - float(dOut) / float(P.mode2.y); sigP = P.misc.x * s * s; }
    for (int i = 0; i < Q; i++) {
        float3 cc = float3(C[i]);
        float cu = dot(cc, u);
        float Si = (1.0 - 0.5 * om) * W[i] * dot(3.0 * (cc - u) + 9.0 * cu * cc, F);
        float post;
        if (P.mode.x == 2) {   // regularized: f_neq rebuilt from its 2nd-order Hermite projection
            float qxx = cc.x * cc.x - 1.0 / 3.0, qyy = cc.y * cc.y - 1.0 / 3.0, qzz = cc.z * cc.z - 1.0 / 3.0;
            float f1 = 4.5 * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0 * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
            post = fe[i] + (1.0 - om) * f1 + Si;
        } else if (P.mode.x == 1) {   // MRT in the Hermite basis: stress modes relax at omega, ghost modes at 1.2
            float qxx = cc.x * cc.x - 1.0 / 3.0, qyy = cc.y * cc.y - 1.0 / 3.0, qzz = cc.z * cc.z - 1.0 / 3.0;
            float f1 = 4.5 * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0 * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
            post = fe[i] + (1.0 - om) * f1 + (1.0 - 1.2) * (fl[i] - fe[i] - f1) + Si;
        } else {
            post = fl[i] - om * (fl[i] - fe[i]) + Si;
        }
        if (sig > 0.0) post += sig * (feq(i, 1.0, uF) - post);
        if (sigP > 0.0) post += sigP * (feq(i, 1.0, u) - feq(i, rho, u));   // relax density only
        fA[i * N + idx] = post;
    }
    mOut[idx] = float4(u, rho);
    float ma = length(u) * 1.7320508;
    if (isnan(ma) || isnan(rho)) red[1] = 1u;
    else { uint o; InterlockedMax(red[0], asuint(ma), o); }
}

// ---------------------------------------------------------------- stream + walls + momentum exchange
void flushPart(int part, float3 aF, float3 aT) {
    uint b = 8u + 12u * uint(part);
    atomicAddFixed(b + 0, aF.x); atomicAddFixed(b + 2, aF.y); atomicAddFixed(b + 4, aF.z);
    atomicAddFixed(b + 6, aT.x); atomicAddFixed(b + 8, aT.y); atomicAddFixed(b + 10, aT.z);
}

[shader("compute")][numthreads(32, 2, 2)]
void lbmStream(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int3 g = int3(gid);
    int N = P.dim.w;
    int curPart = -1; float3 aF = float3(0.0, 0.0, 0.0), aT = float3(0.0, 0.0, 0.0);
    if (inside(g, P.dim)) {
        uint idx = cellIndex(g, P.dim);
        float sx = geo[idx].x;
        if (sx <= 0.0) {
            for (int i = 0; i < Q; i++) fB[i * N + idx] = fA[i * N + idx];
        } else {
            for (int i = 0; i < Q; i++) {
                int3 s = g - C[i];
                if (!inside(s, P.dim)) { fB[i * N + idx] = fA[i * N + idx]; continue; }   // shell cells are reset by collide
                uint sidx = cellIndex(s, P.dim);
                uint code = linkCode(i, idx, N);
                float q; int pid;
                if (code == 0u) {
                    float2 gs = geo[sidx];
                    if (gs.x > 0.0) { fB[i * N + idx] = fA[i * N + sidx]; continue; }
                    q = 0.5; pid = asint(gs.y);               // solid neighbour without a sampled crossing (fallback)
                } else {
                    q = float(code & 255u) / 255.0;
                    uint pc = code >> 8; pid = pc == 255u ? -2 : int(pc) - 1;
                }
                q = clamp(q, 0.02, 0.98);
                // Link crosses a wall: interpolated (Bouzidi) bounce-back of the population leaving x toward the wall.
                int o = OPP(i);
                float fo = fA[o * N + idx];
                float3 ci = float3(C[i]);
                float3 wp = float3(g) - q * ci;
                float3 uw = wallVelocity(P, pid, wp);
                float mw = 6.0 * W[i] * dot(ci, uw);
                float v;
                if (q < 0.5) {
                    int3 x2 = g + C[i];
                    if (inside(x2, P.dim) && geo[cellIndex(x2, P.dim)].x > 0.0 && linkCode(o, idx, N) == 0u)
                        v = 2.0 * q * fo + (1.0 - 2.0 * q) * fA[o * N + cellIndex(x2, P.dim)] + mw;
                    else v = fo + mw;
                } else {
                    v = fo / (2.0 * q) + (2.0 * q - 1.0) / (2.0 * q) * fA[i * N + idx] + mw / (2.0 * q);
                }
                fB[i * N + idx] = v;
                if (pid >= 0) {
                    // Galilean-invariant momentum exchange (Wen et al. 2014) on populations relative to w_i rho0.
                    float3 dP = (fo - W[i]) * (-ci - uw) - (v - W[i]) * (ci - uw);
                    float3 tq = cross(wp - P.center.xyz, dP);
                    if (curPart < 0) curPart = pid;
                    if (pid == curPart) { aF += dP; aT += tq; }
                    else flushPart(pid, dP, tq);
                }
            }
        }
    }
    // One wave-wide sum when every contributing lane hit the same part (the common case), else per-lane atomics.
    int mx = WaveActiveMax(curPart);
    bool same = WaveActiveAllTrue(curPart < 0 || curPart == mx);
    if (same) {
        if (mx >= 0) {
            float3 sF = WaveActiveSum(aF), sT = WaveActiveSum(aT);
            if (WaveIsFirstLane()) flushPart(mx, sF, sT);
        }
    } else if (curPart >= 0) flushPart(curPart, aF, aT);
}

// ---------------------------------------------------------------- diagnostics
/// Sum of rho and fluid-cell count over the macro field (mIn = the latest macro).
[shader("compute")][numthreads(128, 1, 1)]
void lbmMass(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    float r = 0.0, c = 0.0;
    if (int(gid.x) < P.dim.w) { float4 m = mIn[gid.x]; if (m.w > 0.0) { r = m.w; c = 1.0; } }
    r = WaveActiveSum(r); uint n = WaveActiveCountBits(c > 0.0);
    if (WaveIsFirstLane()) { atomicAddFixed(4, r); uint o; InterlockedAdd(red[2], n, o); }
}

/// Flow velocity at each sample point (grid coordinates in scene[layout.y + i]): nearest fluid node, searching
/// outward along the axes up to 4 cells (Swift does this on the CPU from the shared macro buffer).
[shader("compute")][numthreads(64, 1, 1)]
void lbmSample(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(gid.x);
    if (i >= P.layout.z) return;
    float3 gp = scene[P.layout.y + i].xyz;
    int3 c0 = int3(round(gp));
    float4 found = float4(0.0, 0.0, 0.0, -1.0);
    bool done = false;
    for (int r = 0; r <= 4 && !done; r++) {
        for (int d = 0; d < 7 && !done; d++) {
            int3 off = int3(0, 0, 0);
            if (d > 0) { int a = (d - 1) / 2; int v = (d % 2) == 1 ? r : -r; off = int3(a == 0 ? v : 0, a == 1 ? v : 0, a == 2 ? v : 0); }
            int3 c = c0 + off;
            if (!inside(c, P.dim)) continue;
            float4 m = mIn[cellIndex(c, P.dim)];
            if (m.w > 0.0) { found = m; done = true; }
        }
    }
    uint o = uint(P.layout.w + 4 * i);
    red[o] = asuint(found.x); red[o + 1] = asuint(found.y); red[o + 2] = asuint(found.z); red[o + 3] = asuint(found.w);
}

// ---------------------------------------------------------------- visualisation
float3 turbo(float t) {
    t = clamp(t, 0.0, 1.0);
    const float4 kr = float4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const float4 kg = float4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const float4 kb = float4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const float2 kr2 = float2(-152.94239396, 59.28637943), kg2 = float2(4.27729857, 2.82956604), kb2 = float2(-89.90310912, 27.34824973);
    float4 v4 = float4(1.0, t, t * t, t * t * t); float2 v2 = v4.zw * v4.z;
    return clamp(float3(dot(v4, kr) + dot(v2, kr2), dot(v4, kg) + dot(v2, kg2), dot(v4, kb) + dot(v2, kb2)), 0.0, 1.0);
}
uint packRGBA8(float4 c) {
    uint4 b = uint4(round(saturate(c) * 255.0));
    return b.x | (b.y << 8) | (b.z << 16) | (b.w << 24);
}

/// Slice through the domain into links (u7) as RGBA8: D.i = (axis, layer, field, width), D.f = (top, frame vel).
/// axis 0 -> (y,z) plane at x = layer, 1 -> (x,z) at y, 2 -> (x,y) at z. field 0 speed, 1 pressure, 2 vorticity.
/// The slice's max raw value goes to red[6] (non-negative float bits order like uints) for the CPU auto-range.
[shader("compute")][numthreads(16, 16, 1)]
void lbmSlice(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int axis = D.i.x, layer = D.i.y, field = D.i.z, width = D.i.w;
    int height = axis == 2 ? P.dim.y : P.dim.z;
    int2 t = int2(gid.xy);
    if (t.x >= width || t.y >= height) return;
    uint px = uint(t.y * width + t.x);
    int3 g = axis == 0 ? int3(layer, t.x, t.y) : (axis == 1 ? int3(t.x, layer, t.y) : int3(t.x, t.y, layer));
    if (!inside(g, P.dim)) { links[px] = 0u; return; }
    float4 m = mIn[cellIndex(g, P.dim)];
    if (m.w < 0.0) { links[px] = packRGBA8(float4(0.08, 0.08, 0.09, 1.0)); return; }
    float r, v;
    float top = max(D.f.x, 1e-9);
    if (field == 0) { r = length(m.xyz + D.f.yzw); v = r / top; }
    else if (field == 1) { float dp = (m.w - 1.0) / 3.0; r = abs(dp); v = 0.5 + 0.5 * dp / top; }
    else {
        float3 d[3];
        for (int b = 0; b < 3; b++) {
            int3 e = int3(b == 0 ? 1 : 0, b == 1 ? 1 : 0, b == 2 ? 1 : 0);
            int3 gp = clamp(g + e, int3(0, 0, 0), P.dim.xyz - 1), gm = clamp(g - e, int3(0, 0, 0), P.dim.xyz - 1);
            d[b] = 0.5 * (mIn[cellIndex(gp, P.dim)].xyz - mIn[cellIndex(gm, P.dim)].xyz);
        }
        float3 w = float3(d[1].z - d[2].y, d[2].x - d[0].z, d[0].y - d[1].x);
        r = length(w); v = r / top;
    }
    if (!isnan(r) && !isinf(r)) { uint o; InterlockedMax(red[6], asuint(r), o); }
    links[px] = packRGBA8(float4(turbo(clamp(v, 0.0, 1.0)), 0.85));
}

/// Massless tracers (grid coordinates, in mOut) advected with the lattice velocity for D.f.x steps; respawn upstream
/// on exit. D.i.x = count.
[shader("compute")][numthreads(128, 1, 1)]
void lbmParticles(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    if (int(gid.x) >= D.i.x) return;
    float steps = D.f.x;
    float4 q = mOut[gid.x];
    int3 g = int3(round(q.xyz));
    bool ok = inside(g, P.dim);
    float4 m = ok ? mIn[cellIndex(g, P.dim)] : float4(0.0, 0.0, 0.0, -1.0);
    if (ok && m.w > 0.0) { q.xyz += m.xyz * steps; q.w += steps; }
    g = int3(round(q.xyz));
    if (!inside(g, P.dim) || m.w <= 0.0 || q.w > 4.0 * float(P.dim.x + P.dim.y + P.dim.z)) {
        uint h = gid.x * 747796405u + uint(P.mode2.w) * 2891336453u;
        h ^= h >> 16; h *= 2246822519u; h ^= h >> 13;
        float3 rr = float3(float(h & 1023u), float((h >> 10) & 1023u), float((h >> 20) & 1023u)) / 1023.0;
        float3 dimf = float3(P.dim.xyz) - 3.0;
        float3 np = 1.0 + rr * dimf;
        float3 uf = P.uFar.xyz; float lu = length(uf);
        if (lu > 1e-6) {
            float3 dir = uf / lu;
            int ax = abs(dir.x) > abs(dir.y) ? (abs(dir.x) > abs(dir.z) ? 0 : 2) : (abs(dir.y) > abs(dir.z) ? 1 : 2);
            np[ax] = dir[ax] > 0.0 ? 2.0 : dimf[ax];
        }
        q = float4(np, 0.0);
    }
    mOut[gid.x] = q;
}
