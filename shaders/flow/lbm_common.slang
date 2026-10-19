// Lattice-Boltzmann CFD kernels (descended from Sources/Flow/LBMShaders.swift, the Metal source of the Swift solver).
// Included by lbm19.slang / lbm27.slang (fp32 population storage) and lbm19h.slang / lbm27h.slang (fp16 storage,
// FP16 defined), which define Q (velocity set) before including this file.
//
// Grid: up to MAX_LEVELS nested, world-axis-aligned boxes (block-structured local refinement, ratio 2). Level 0 is the
// whole domain; level l + 1 spans the level-l nodes childLo..childHi (inclusive) with half the spacing and half the
// time step (acoustic scaling: lattice velocities are equal on every level, nu_lat doubles per level). A level is
// stepped once, then its child twice. Coarse/fine coupling (Lagrava et al. 2012 / Dupuis & Chopard 2003, on moments):
//   * coarse -> fine: every node of the fine box's outer layer ("ghost") rebuilds its post-collision set from the
//     parent's (rho, u, Pi_neq, tau) on the box surface ("records", written by the parent's step), interpolated
//     linearly in space and time (first fine substep: mean of the parent's two latest records), with the
//     non-equilibrium part rescaled Pi_f = Pi_c tau_f / (2 tau_c) and tau_f - 1/2 = 2 (tau_c - 1/2);
//   * fine -> coarse: on its second substep the fine nodes of the three layers inside the ghosts write their moments to
//     a band of records; lbmRestrict then rebuilds every parent node of the layer just inside the box ("restricted")
//     from the coincident fine node's (rho, u) and the (1/4, 1/2, 1/4)^3-filtered Pi_neq and tau of its 27 fine
//     neighbours (no fine-grid noise aliased onto the coarse grid), Pi_c = Pi_f 2 tau_c / tau_f, written into the
//     parent's populations at the parent's step parity. Parent nodes deeper inside the box ("covered") are idle;
//     coincident fine nodes copy their macro there (slices, sampling, mass).
// Parts and rotors live on the finest level only (its box contains the craft with a margin), so forces are summed
// in finest-level lattice units.
//
// Populations: ONE buffer for all levels, SoA per level (slot k of cell n of a level at pop + k*N + n), esoteric-pull
// streaming (Lehmann 2022): every LBM step is one fused kernel (lbmStep) in which each cell loads its incoming
// populations from, and stores its post-collision populations back to, the same 2(Q-1)+1 slots (its own and its
// +c_k neighbours'), alternating with the level's step parity. Stored value: (f_i - feq_i(1, u_s)) * FSCALE with u_s
// the shift velocity (the far field at layout, kept until it drifts: lbmRescale re-encodes), so the free stream is
// stored as ~0 and fp16 resolves small pressure differences; fp16 (FSCALE 2^15) or fp32 (FSCALE 1), fp32 arithmetic.
// Lattice units throughout (dx = dt = 1 on each level, rho0 = 1, cs^2 = 1/3).
//
// Binding model (pw/compute.h): b0 = per-dispatch constants, u1..u8 = storage buffers. Slots are shared by role:
//   u1 scene  float4: level blocks (LEVEL_STRIDE each: 16 params + 3 float4 per rotor), previous-layout level
//                     descriptors (REGRID_BASE), parts (8 float4 each) at layout.x, sample points at layout.y
//   u2 fS     FT    : populations of every level (single buffer, esoteric pull)
//   u3 aux    float : coarse/fine records (12 floats per parent surface node and parity; per fine level a band of 12
//                     floats per node of its three layers inside the ghosts) then the wall slots (previous
//                     post-collision set of near-wall cells, Q floats each; exact Bouzidi)
//   u4 mOut   float4: macro (u, rho; rho < 0 = solid) written by lbmStep | particles: tracer positions
//   u5 mIn    float4: previous macro | voxelize: part SDF grids (float data packed 4 per float4)
//   u6 geo    float2: (signed distance in cells, part id bits: -1 none, -2 ground, k = part slot)
//   u7 links  uint  : per level at cell base * (LW + 1): wall crossings, two 16-bit link codes per uint
//                     ([i/2]*N + cell), then the wall slot of the cell ([LW*N + cell], 0xFFFFFFFF = none) | slice: RGBA8
//   u8 red    uint  : reductions: [0] max lattice Mach bits, [1] NaN flag, [2] fluid cells, [4..5] sum rho,
//                     [6] slice range bits, [7] wall-slot counter, [8 + 12k] force/torque of part k
//                     (6 x 64-bit fixed point), then 4 float bits per sample point
// Float atomics are 64-bit fixed-point integer atomics after a wave (SIMD-group) reduction (D3D12 SM 6.0 has no
// float atomics; Metal only has a weak compare-exchange).

struct Dispatch {
    int4 i;      // kernel-specific integers
    float4 f;    // kernel-specific floats
    int4 j;      // kernel-specific integers
};
ConstantBuffer<Dispatch> D : register(b0);

#ifdef FP16
typedef half FT;
static const float FSCALE = 32768.0;
#else
typedef float FT;
static const float FSCALE = 1.0;
#endif

RWStructuredBuffer<float4> scene : register(u1);
RWStructuredBuffer<FT> fS : register(u2);
RWStructuredBuffer<float> aux : register(u3);
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
// Directions come in pairs (k odd, k + 1 = opposite of k) with equal weights, which esoteric pull relies on.
int OPP(int i) { return i == 0 ? 0 : ((i & 1) != 0 ? i + 1 : i - 1); }
static const int LW = (Q + 1) / 2;   // link-code words per cell; the wall-slot word follows them
static const int REC = 12;
static const float WALL_NU_MIN = 0.01 / 3.0;   // wall-model nodes keep tau >= 0.51 (stability next to a slip wall)           // floats per coarse/fine record: u.xyz, rho, Pi (xx yy zz xy xz yz), tau, unused

// ---------------------------------------------------------------- params (one block per level)
static const int MAX_LEVELS = 4;
static const int LEVEL_STRIDE = 64;
static const int ROTOR_OFFSET = 16;
static const int REGRID_BASE = MAX_LEVELS * LEVEL_STRIDE;   // 2 float4 per previous-layout level (lbmRegrid)
static const int PART_STRIDE = 8;
struct Params {
    int4 dim;        // nx, ny, nz, N
    int4 mode;       // collision (0 bgk, 1 trt/"mrt", 2 regularized), turbulence (0 none, 1 smag, 2 wale), interpolatedBB, rotorCount
    int4 mode2;      // partCount, spongeCells (level 0, else 0), hasGround, update counter
    float4 relax;    // omega0, tau0, Smagorinsky Cs, WALE Cw
    float4 uFar;     // far-field velocity (lattice), w = inflow face mask (bit 2a: low face of axis a, 2a + 1: high face)
    float4 accel;    // uniform frame acceleration (lattice / step), w = Smagorinsky wall-damping length (cells, 0 = off)
    float4 center;   // CoM in grid coordinates (cells), w = dx (m)
    float4 ground;   // x = ground plane y in grid coordinates, yzw = ground velocity (lattice)
    float4 misc;     // x sponge strength, y accuracy flags (bit 0: inflate thin parts only, bit 1: refined crossings,
                     // bit 2: log-law wall model), z dt (s), w outflow face mask (faces that are neither in nor out are lateral)
    int4 layout;     // x part base (float4 index), y sample base, z sample count, w reduction offset of the samples
    int4 lvl;        // x cell base, y parent level (-1 none), z child level (-1 none), w level index
    int4 parent;     // xyz this box's low corner in parent coordinates, w aux offset of this level's ghost records
    int4 childLo;    // xyz child box low corner (own coordinates), w aux offset of the records this level writes
    int4 childHi;    // xyz child box high corner (inclusive), w aux offset of the wall slots
    float4 shift;    // xyz stored-population shift velocity u_s (lattice), w (int bits) aux offset of this level's restriction band
    float4 view;     // xyz this level's node 0 in level-0 grid coordinates, w = 2^level (own cells per level-0 cell)
};

Params loadParams(int level) {
    int b = level * LEVEL_STRIDE;
    Params p;
    p.dim = asint(scene[b]); p.mode = asint(scene[b + 1]); p.mode2 = asint(scene[b + 2]);
    p.relax = scene[b + 3]; p.uFar = scene[b + 4]; p.accel = scene[b + 5]; p.center = scene[b + 6]; p.ground = scene[b + 7];
    p.misc = scene[b + 8]; p.layout = asint(scene[b + 9]); p.lvl = asint(scene[b + 10]); p.parent = asint(scene[b + 11]);
    p.childLo = asint(scene[b + 12]); p.childHi = asint(scene[b + 13]); p.shift = scene[b + 14]; p.view = scene[b + 15];
    return p;
}

/// Population addressing of one level: element (slot k, cell n) at pop + k*N + n.
struct Grid {
    int4 dim;
    uint pop;
    float3 us;
};
Grid gridOf(Params P) {
    Grid G;
    G.dim = P.dim; G.pop = uint(P.lvl.x) * uint(Q); G.us = P.shift.xyz;
    return G;
}

struct GPart {
    float4 rot;      // world-from-part quaternion (xyz, w)
    float4 pos;      // part origin relative to the CoM (m); w = bound radius (m)
    float4 linVel;   // lattice units, relative to the domain frame
    float4 angVel;   // rad per level-0 lattice step (world axes); w = extra inflation (m)
    int4 grid;       // nx, ny, nz, offset into grid data
    float4 origin;   // part-local corner of the sdf grid (m), w = smallest cell size (m)
    int4 flags;      // x thin, y disabled
    float4 h;        // xyz: sdf cell size per part axis (m; anisotropic so thin wings keep their real thickness), w: band (m)
};
GPart loadPart(Params P, int k) {
    int b = P.layout.x + k * PART_STRIDE;
    GPart g;
    g.rot = scene[b]; g.pos = scene[b + 1]; g.linVel = scene[b + 2]; g.angVel = scene[b + 3];
    g.grid = asint(scene[b + 4]); g.origin = scene[b + 5]; g.flags = asint(scene[b + 6]); g.h = scene[b + 7];
    return g;
}

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }
uint cellIndex(int3 g, int4 dim) { return uint(g.x + dim.x * (g.y + dim.y * g.z)); }
int3 cellCoord(int n, int4 dim) { return int3(n % dim.x, (n / dim.x) % dim.y, n / (dim.x * dim.y)); }
bool inside(int3 g, int4 dim) { return all(g >= 0) && g.x < dim.x && g.y < dim.y && g.z < dim.z; }
bool onBoundary(int3 g, int4 dim) { return any(g == 0) || g.x == dim.x - 1 || g.y == dim.y - 1 || g.z == dim.z - 1; }
/// Parent nodes strictly inside the child box: idle in the parent (restricted from / covered by the child).
bool covered(Params P, int3 g) { return P.lvl.z >= 0 && all(g > P.childLo.xyz) && all(g < P.childHi.xyz); }
/// Parent nodes on the child box surface: they write the child's ghost records.
bool onChildSurface(Params P, int3 g) {
    return P.lvl.z >= 0 && all(g >= P.childLo.xyz) && all(g <= P.childHi.xyz) && (any(g == P.childLo.xyz) || any(g == P.childHi.xyz));
}

float feq(int i, float rho, float3 u) {
    float cu = dot(float3(C[i]), u);
    return W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * dot(u, u));
}
/// Regularized non-equilibrium part of direction i from Pi_neq (xx yy zz xy xz yz).
float fneq(int i, float pxx, float pyy, float pzz, float pxy, float pxz, float pyz) {
    float3 cc = float3(C[i]);
    float qxx = cc.x * cc.x - 1.0 / 3.0, qyy = cc.y * cc.y - 1.0 / 3.0, qzz = cc.z * cc.z - 1.0 / 3.0;
    return 4.5 * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0 * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
}

// Population slot access. `dir` = the direction of the population held in that slot (slot k holds k or OPP(k)
// depending on the parity), which selects the shift.
float ldF(Grid G, int slot, int dir, uint cell) { return float(fS[G.pop + uint(slot) * uint(G.dim.w) + cell]) * (1.0 / FSCALE) + feq(dir, 1.0, G.us); }
void stF(Grid G, int slot, int dir, uint cell, float v) { fS[G.pop + uint(slot) * uint(G.dim.w) + cell] = FT((v - feq(dir, 1.0, G.us)) * FSCALE); }

/// Esoteric-pull store of a full post-collision set at step parity t (out-of-box neighbour slots are skipped:
/// only boundary cells, which never load, would read them).
void storeSet(Grid G, int3 g, uint n, int t, float post[Q]) {
    stF(G, 0, 0, n, post[0]);
    for (int k = 1; k < Q; k += 2) {
        int3 j = g + C[k];
        if (inside(j, G.dim)) stF(G, t != 0 ? k + 1 : k, k, cellIndex(j, G.dim), post[k]);
        stF(G, t != 0 ? k : k + 1, k + 1, n, post[k + 1]);
    }
}

/// Last post-collision set of cell n, stored at parity 1 - t (t = parity of the next step); `outside` for neighbours
/// beyond the box.
void loadLastSet(Grid G, int3 g, uint n, int t, float3 outside, out float post[Q]) {
    post[0] = ldF(G, 0, 0, n);
    for (int k = 1; k < Q; k += 2) {
        int3 j = g + C[k];
        post[k] = inside(j, G.dim) ? ldF(G, t != 0 ? k : k + 1, k, cellIndex(j, G.dim)) : feq(k, 1.0, outside);
        post[k + 1] = ldF(G, t != 0 ? k + 1 : k, k + 1, n);
    }
}

uint linkBase(Params P) { return uint(P.lvl.x) * uint(LW + 1); }
uint linkCode(Params P, int i, uint idx) {
    uint w = links[linkBase(P) + uint(i >> 1) * uint(P.dim.w) + idx];
    return (i & 1) != 0 ? (w >> 16) : (w & 0xFFFFu);
}

/// Index of a node on the surface of a box of s nodes per axis (r = box-relative coordinates, some r_a = 0 or s_a - 1).
uint surfIndex(int3 r, int3 s) {
    if (r.z == 0) return uint(r.x + s.x * r.y);
    if (r.z == s.z - 1) return uint(s.x * s.y + r.x + s.x * r.y);
    int b = 2 * s.x * s.y, zz = r.z - 1;
    if (r.y == 0) return uint(b + r.x + s.x * zz);
    if (r.y == s.y - 1) return uint(b + s.x * (s.z - 2) + r.x + s.x * zz);
    b += 2 * s.x * (s.z - 2);
    int yy = r.y - 1;
    if (r.x == 0) return uint(b + yy + (s.y - 2) * zz);
    return uint(b + (s.y - 2) * (s.z - 2) + yy + (s.y - 2) * zz);
}
uint surfCount(int3 s) { return uint(2 * s.x * s.y + 2 * s.x * (s.z - 2) + 2 * (s.y - 2) * (s.z - 2)); }
/// Inverse of surfIndex.
int3 surfCoord(uint i, int3 s) {
    uint a = uint(s.x * s.y);
    if (i < a) return int3(int(i) % s.x, int(i) / s.x, 0);
    i -= a;
    if (i < a) return int3(int(i) % s.x, int(i) / s.x, s.z - 1);
    i -= a;
    uint b = uint(s.x * (s.z - 2));
    if (i < b) return int3(int(i) % s.x, 0, int(i) / s.x + 1);
    i -= b;
    if (i < b) return int3(int(i) % s.x, s.y - 1, int(i) / s.x + 1);
    i -= b;
    uint c = uint((s.y - 2) * (s.z - 2));
    if (i < c) return int3(0, int(i) % (s.y - 2) + 1, int(i) / (s.y - 2) + 1);
    i -= c;
    return int3(s.x - 1, int(i) % (s.y - 2) + 1, int(i) / (s.y - 2) + 1);
}
/// Layer of a node counted from the box boundary (0 = ghost layer).
int layerOf(int3 g, int4 dim) { return min(min(min(g.x, dim.x - 1 - g.x), min(g.y, dim.y - 1 - g.y)), min(g.z, dim.z - 1 - g.z)); }
/// Restriction band slot (layers 1..3) of node g of a fine level, in floats from the band base.
uint bandIndex(int3 g, int4 dim) {
    int k = layerOf(g, dim);
    uint o = 0u;
    for (int j = 1; j < k; j++) o += surfCount(dim.xyz - 2 * j);
    return (o + surfIndex(g - k, dim.xyz - 2 * k)) * uint(REC);
}

/// Parent side: record (rho, u, Pi_neq, tau) of a child-surface node for parity slot `par`.
void writeRecord(Params P, int3 g, int par, float3 u, float rho, float pxx, float pyy, float pzz, float pxy, float pxz, float pyz, float tau) {
    int3 s = P.childHi.xyz - P.childLo.xyz + 1;
    uint o = uint(P.childLo.w) + (uint(par) * surfCount(s) + surfIndex(g - P.childLo.xyz, s)) * uint(REC);
    aux[o] = u.x; aux[o + 1] = u.y; aux[o + 2] = u.z; aux[o + 3] = rho;
    aux[o + 4] = pxx; aux[o + 5] = pyy; aux[o + 6] = pzz; aux[o + 7] = pxy; aux[o + 8] = pxz; aux[o + 9] = pyz;
    aux[o + 10] = tau; aux[o + 11] = 0.0;
}

/// 64-bit two's-complement fixed point (2^-24 resolution) accumulated with 32-bit integer atomics: lo word, then the
/// hi word plus the carry out of lo. Integer addition is order independent, so the sums are deterministic.
/// |x * 2^24| < 2^31 (every per-wave sum) is split exactly via int; larger magnitudes via floor (exact there too,
/// since such a float is a multiple of 2^8 and both halves are representable).
static const float FIXED_SCALE = 16777216.0;
void atomicAddFixed(uint i, float x) {
    float v = round(x * FIXED_SCALE);
    if (v == 0.0 || isnan(v)) return;
    uint lo, hi;
    if (abs(v) < 2147483648.0) {
        int iv = int(v);
        lo = uint(iv); hi = iv < 0 ? 0xFFFFFFFFu : 0u;
    } else {
        float hiF = floor(v / 4294967296.0);
        lo = uint(v - hiF * 4294967296.0); hi = uint(int(hiF));
    }
    uint old;
    InterlockedAdd(red[i], lo, old);
    uint carry = (old + lo < old) ? 1u : 0u;
    if (hi + carry != 0u) { uint o2; InterlockedAdd(red[i + 1], hi + carry, o2); }
}

// ---------------------------------------------------------------- geometry
float gridValue(int o) { float4 v = mIn[uint(o) >> 2]; int c = o & 3; return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w)); }

float sampleGrid(GPart p, float3 l) {   // mIn = grid data in lbmVoxelize
    float3 h = p.h.xyz;
    float3 u = (l - p.origin.xyz) / h - 0.5;
    float3 n = float3(p.grid.xyz);
    if (any(u < 0.0) || any(u > n - 1.0)) {
        float3 lo = p.origin.xyz, hi = p.origin.xyz + n * h;
        float3 dd = max(max(lo - l, l - hi), 0.0);
        return length(dd) + p.h.w;   // the grid keeps a band of p.h.w (m) around the surface
    }
    int3 i0 = min(int3(floor(u)), p.grid.xyz - 2);
    float3 fr = u - float3(i0);
    int nx = p.grid.x, ny = p.grid.y;
    int b = p.grid.w + i0.x + nx * (i0.y + ny * i0.z);
    int sy = nx, sz = nx * ny;
    float g000 = gridValue(b), g100 = gridValue(b + 1);
    float g010 = gridValue(b + sy), g110 = gridValue(b + sy + 1);
    float g001 = gridValue(b + sz), g101 = gridValue(b + sz + 1);
    float g011 = gridValue(b + sy + sz), g111 = gridValue(b + sy + sz + 1);
    float c00 = lerp(g000, g100, fr.x), c10 = lerp(g010, g110, fr.x);
    float c01 = lerp(g001, g101, fr.x), c11 = lerp(g011, g111, fr.x);
    return lerp(lerp(c00, c10, fr.y), lerp(c01, c11, fr.y), fr.z);
}

/// Wall velocity (lattice) of the owner of a wall point g (grid coordinates of this level; part slot pid, -2 = ground).
float3 wallVelocity(Params P, int pid, float3 g) {
    if (pid == -2) return P.ground.yzw;
    if (pid < 0) return float3(0.0, 0.0, 0.0);
    GPart p = loadPart(P, pid);
    float3 r = g - (P.center.xyz + p.pos.xyz / P.center.w);
    return p.linVel.xyz + cross(p.angVel.xyz * exp2(-float(P.lvl.w)), r);
}

/// Signed distance (m) of the scene at a point relative to the CoM; `part` = owner slot (-2 ground).
/// Sheets get a finite core (>= 0.15 dx); Swift inflated every part by 0.3 of its sdf cell (accuracy flag bit 0 off);
/// with bit 0 closed bodies keep their true volume.
float sceneSDF(Params P, float3 pm, out int part) {
    float dx = P.center.w;
    float best = 1e9; part = -1;
    bool thinOnly = (asint(P.misc.y) & 1) != 0;
    for (int k = 0; k < P.mode2.x; k++) {
        GPart p = loadPart(P, k);
        if (p.flags.y != 0) continue;
        float3 d = pm - p.pos.xyz;
        if (length(d) > p.pos.w + 2.0 * dx) continue;
        // Sheets (and sub-0.15-cell plates) get a core of >= 0.15 dx so the 1/8-step link sampling cannot miss them.
        float inflate = p.flags.x != 0 ? max(0.3 * p.origin.w, 0.15 * dx) : (thinOnly ? 0.0 : 0.3 * p.origin.w);
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
/// Per node of level D.i.z: signed distance (cells) and nearest part; for near-wall fluid nodes the wall crossing of
/// every link, sampled at 1/8 steps along x -> x - c_i (sheets thinner than a cell still cut the link). Link code:
/// 0 = no wall, else low byte q*255 (1..255), high byte part slot + 1 (255 = ground). With accuracy flag bit 1 the
/// bracketing 1/8 interval is refined by two secant (regula falsi) iterations instead of one linear interpolation.
/// D.i.x = index of the level's next LBM step (its parity selects the esoteric slots), D.i.y = wall-slot capacity.
/// Also: (a) cells uncovered by a moving part since the last update get equilibrium populations at the wall velocity
/// (written to the slots their last post-collision set would occupy); (b) every near-wall fluid cell is given a wall
/// slot and its last post-collision set is copied there, so lbmStep can do exact interpolated bounce-back even across
/// sheets thinner than a cell (where the neighbour behind the wall is fluid and owns the slots esoteric pull would
/// otherwise reuse). Covered (idle) parent nodes are plain fluid.
[shader("compute")][numthreads(64, 1, 1)]
void lbmVoxelize(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
    int N = P.dim.w;
    int n = int(gid.x);
    if (n >= N) return;
    int3 g = cellCoord(n, P.dim);
    uint idx = uint(n), gi = uint(P.lvl.x) + idx;
    uint lb = linkBase(P);
    if (covered(P, g)) {
        geo[gi] = float2(1e9, asfloat(-1));
        for (int w = 0; w < LW; w++) links[lb + uint(w) * uint(N) + idx] = 0u;
        links[lb + uint(LW) * uint(N) + idx] = 0xFFFFFFFFu;
        return;
    }
    Grid G = gridOf(P);
    float dx = P.center.w;
    float3 pm = (float3(g) - P.center.xyz) * dx;
    int bp;
    float s0 = sceneSDF(P, pm, bp);
    float2 old = geo[gi];
    geo[gi] = float2(s0 / dx, asfloat(bp));
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
        if ((i & 1) == 0) { packed = code; if (i == Q - 1) links[lb + uint(i >> 1) * uint(N) + idx] = packed; }
        else links[lb + uint(i >> 1) * uint(N) + idx] = packed | (code << 16);
    }
    // Populations: the next step has parity t, so the last post-collision set was stored with parity 1 - t.
    int t = D.i.x & 1;
    bool fresh = s0 > 0.0 && old.x <= 0.0;
    float post[Q];
    for (int i = 0; i < Q; i++) post[i] = 0.0;
    if (fresh) {
        float3 uw = wallVelocity(P, asint(old.y), float3(g));
        for (int i = 0; i < Q; i++) post[i] = feq(i, 1.0, uw);
        storeSet(G, g, idx, 1 - t, post);
    }
    uint slot = 0xFFFFFFFFu;
    if (nearWall) {
        uint s;
        InterlockedAdd(red[7], 1u, s);
        if (s < uint(D.i.y)) {
            slot = s;
            if (!fresh) loadLastSet(G, g, idx, t, P.uFar.xyz, post);
            uint wb = uint(P.childHi.w) + slot * uint(Q);
            for (int i = 0; i < Q; i++) aux[wb + uint(i)] = post[i];
        }
    }
    links[lb + uint(LW) * uint(N) + idx] = slot;
}

// ---------------------------------------------------------------- init / rescale / clear
/// Far-field equilibrium everywhere on level D.i.z (stored for the step D.i.x), macro (both buffers) = far field,
/// and the child's records (both parities) = far field at rest stress.
[shader("compute")][numthreads(64, 1, 1)]
void lbmInit(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
    int n = int(gid.x);
    if (n >= P.dim.w) return;
    int3 g = cellCoord(n, P.dim);
    float post[Q];
    for (int i = 0; i < Q; i++) post[i] = feq(i, 1.0, P.uFar.xyz);
    storeSet(gridOf(P), g, uint(n), 1 - (D.i.x & 1), post);
    uint gi = uint(P.lvl.x) + uint(n);
    mOut[gi] = float4(P.uFar.xyz, 1.0); mIn[gi] = float4(P.uFar.xyz, 1.0);
    if (onChildSurface(P, g))
        for (int par = 0; par < 2; par++) writeRecord(P, g, par, P.uFar.xyz, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, P.relax.y);
}

/// Re-layout carry-over (after lbmInit): every cell of level D.i.z takes equilibrium populations, and child-surface
/// records, at the (rho, u) of the finest level of the PREVIOUS layout containing it (their macro in u4 / u5, bit l of
/// D.j.x set = old level l's latest is in u4; D.j.y = old level count; old level l: dims + cell base at
/// scene[REGRID_BASE + 2l], node 0 in old level-0 coordinates + cells per old level-0 cell at scene[REGRID_BASE + 2l + 1]).
/// This level's node g sits at D.f.xyz + g D.f.w in old level-0 coordinates; old lattice velocities scale by
/// asfloat(D.j.z) (a changed time step). Cells outside the old grid or solid there keep the far field.
[shader("compute")][numthreads(64, 1, 1)]
void lbmRegrid(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
    int n = int(gid.x);
    if (n >= P.dim.w) return;
    int3 g = cellCoord(n, P.dim);
    float3 p0 = D.f.xyz + float3(g) * D.f.w;
    float4 m = float4(0.0, 0.0, 0.0, -1.0);
    for (int l = D.j.y - 1; l >= 0; l--) {
        int4 od = asint(scene[REGRID_BASE + 2 * l]);
        float4 ov = scene[REGRID_BASE + 2 * l + 1];
        int3 c = int3(round((p0 - ov.xyz) * ov.w));
        bool ok = l > 0 ? (all(c >= 1) && all(c <= od.xyz - 2)) : inside(c, int4(od.xyz, 0));
        if (!ok) continue;
        uint oi = uint(od.w) + cellIndex(c, int4(od.xyz, 0));
        m = ((D.j.x >> l) & 1) != 0 ? mOut[oi] : mIn[oi];
        break;
    }
    if (!(m.w > 0.0)) return;
    float3 u = m.xyz * asfloat(D.j.z);
    float lu = length(u); if (lu > 0.3) u *= 0.3 / lu;
    float post[Q];
    for (int i = 0; i < Q; i++) post[i] = feq(i, m.w, u);
    storeSet(gridOf(P), g, uint(n), 1 - (D.i.x & 1), post);
    if (onChildSurface(P, g))
        for (int par = 0; par < 2; par++) writeRecord(P, g, par, u, m.w, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, P.relax.y);
}

/// Changes the lattice time step by factor k (u -> k u): f = feq(rho, k u) + k (f - feq(rho, u)), and re-encodes the
/// stored populations from the shift D.f.yzw to the level's current shift. k = D.f.x, D.i.x = index of the next step,
/// D.i.z = level. Each cell transforms the set it will load next step, in place (race free: every slot is loaded by
/// exactly one cell). Solid / boundary cells (whose sets are partly foreign) use the linearised form
/// f = feq(1, k u_s) + k (f - feq(1, u_s)). Child-surface records scale with k.
[shader("compute")][numthreads(64, 1, 1)]
void lbmRescale(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
    int n = int(gid.x);
    if (n >= P.dim.w) return;
    int3 g = cellCoord(n, P.dim);
    if (covered(P, g)) return;
    float k = D.f.x;
    Grid G = gridOf(P), G0 = G;
    G0.us = D.f.yzw;
    int t = D.i.x & 1;
    uint sl[Q]; int sk[Q]; bool ok[Q];
    sl[0] = uint(n); sk[0] = 0; ok[0] = true;
    for (int i = 1; i < Q; i += 2) {
        int3 j = g + C[i];
        sl[i] = uint(n); sk[i] = t != 0 ? i : i + 1; ok[i] = true;
        ok[i + 1] = inside(j, P.dim);
        sl[i + 1] = ok[i + 1] ? cellIndex(j, P.dim) : 0u; sk[i + 1] = t != 0 ? i + 1 : i;
    }
    bool full = geo[uint(P.lvl.x) + uint(n)].x > 0.0;
    float fl[Q]; float rho = 0.0; float3 m = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < Q; i++) {
        full = full && ok[i];
        fl[i] = ok[i] ? ldF(G0, sk[i], i, sl[i]) : W[i];
        rho += fl[i]; m += fl[i] * float3(C[i]);
    }
    float3 u = m / max(rho, 1e-6);
    for (int i = 0; i < Q; i++) {
        if (!ok[i]) continue;
        float v = full ? feq(i, rho, k * u) + k * (fl[i] - feq(i, rho, u)) : feq(i, 1.0, k * G0.us) + k * (fl[i] - feq(i, 1.0, G0.us));
        stF(G, sk[i], i, sl[i], v);
    }
    if (onChildSurface(P, g) && k != 1.0) {
        int3 s = P.childHi.xyz - P.childLo.xyz + 1;
        for (int par = 0; par < 2; par++) {
            uint o = uint(P.childLo.w) + (uint(par) * surfCount(s) + surfIndex(g - P.childLo.xyz, s)) * uint(REC);
            for (int c = 0; c < 3; c++) aux[o + uint(c)] *= k;
            for (int c = 4; c < 10; c++) aux[o + uint(c)] *= k;
        }
    }
}

/// Zeroes red[0 .. D.i.x) (reductions of one update).
[shader("compute")][numthreads(128, 1, 1)]
void lbmClear(uint3 gid : SV_DispatchThreadID) {
    if (int(gid.x) < D.i.x) red[gid.x] = 0u;
}

// ---------------------------------------------------------------- one fused LBM step
void flushPart(int part, float3 aF, float3 aT) {
    uint b = 8u + 12u * uint(part);
    atomicAddFixed(b + 0, aF.x); atomicAddFixed(b + 2, aF.y); atomicAddFixed(b + 4, aF.z);
    atomicAddFixed(b + 6, aT.x); atomicAddFixed(b + 8, aT.y); atomicAddFixed(b + 10, aT.z);
}

/// Level-0 outer face node (previous-step macro): velocity inlet (u = u_inf, rho from the inward neighbour); pressure
/// outlet with a convective velocity (rho = 1, u_b <- u_b - lambda (u_b - u_nb), lambda = the neighbour's outward normal
/// speed; zero gradient where flow enters through an outlet face, e.g. entrainment in hover); free-stream lateral face
/// (u = u_inf, rho from the inward neighbour). With the blockage-sized cross-section the lateral faces see the
/// undisturbed stream; the sponge layers behind every face absorb what still reaches them.
void outerFace(Params P, int3 g, uint gi, out float rb, out float3 ub) {
    int inM = int(P.uFar.w), outM = int(P.misc.w);
    bool onIn = false, onOut = false;
    float3 nOut = float3(0.0, 0.0, 0.0);
    for (int a = 0; a < 3; a++) {
        float3 e = float3(a == 0 ? 1.0 : 0.0, a == 1 ? 1.0 : 0.0, a == 2 ? 1.0 : 0.0);
        if (g[a] == 0) { if ((inM & (1 << (2 * a))) != 0) onIn = true; else if ((outM & (1 << (2 * a))) != 0) { onOut = true; nOut -= e; } }
        if (g[a] == P.dim[a] - 1) { if ((inM & (1 << (2 * a + 1))) != 0) onIn = true; else if ((outM & (1 << (2 * a + 1))) != 0) { onOut = true; nOut += e; } }
    }
    float3 uF = P.uFar.xyz;
    int3 gn = clamp(g, int3(1, 1, 1), P.dim.xyz - 2);
    float4 mn = mIn[uint(P.lvl.x) + cellIndex(gn, P.dim)];
    float rN = mn.w > 0.0 ? mn.w : 1.0;
    float3 uN = mn.w > 0.0 ? mn.xyz : uF;
    if (onOut && !onIn) {
        float4 mb = mIn[gi];
        float3 u0 = mb.w > 0.0 ? mb.xyz : uF;
        float un = dot(uN, normalize(nOut));
        float lam = un > 0.0 ? min(un, 1.0) : 1.0;
        ub = u0 + lam * (uN - u0); rb = 1.0;
    } else { ub = uF; rb = rN; }   // inlet and lateral far field
    float lu = length(ub); if (lu > 0.3) ub *= 0.3 / lu;
    rb = clamp(rb, 0.5, 1.5);
}

/// Esoteric-pull load + walls (interpolated bounce-back, momentum exchange) + collision + store, one cell per thread,
/// on level D.i.z. D.i.x = the level's step index (parity), D.i.y = 1 when every cell must write its macro (last step
/// of the update), D.i.w = coupling flags: bit 0 = second substep of the parent step (ghosts use the parent's latest
/// record only; restrict into the parent now), bit 1 = the parent's latest macro is mOut (else mIn), bit 2 = parity of
/// the parent's latest step.
[shader("compute")][numthreads(64, 1, 1)]
void lbmStep(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
    int N = P.dim.w;
    int n = int(gid.x);
    int t = D.i.x & 1;
    bool lastStep = D.i.y != 0;
    int flags = D.i.w;
    bool sub2 = (flags & 1) != 0;
    bool hasParent = P.lvl.y >= 0;
    int curPart = -1; float3 aF = float3(0.0, 0.0, 0.0), aT = float3(0.0, 0.0, 0.0);
    float ma = 0.0; bool bad = false;
    if (n < N) {
        uint idx = uint(n), gi = uint(P.lvl.x) + idx;
        int3 g = cellCoord(n, P.dim);
        Grid G = gridOf(P);
        // Fine -> coarse: even nodes 2..n-3 coincide with the parent's idle nodes. On the second substep they hand
        // over their macro, and layers 1..3 write the band records lbmRestrict filters into the parent's populations.
        bool feed = hasParent && sub2 && all((g & 1) == 0) && all(g >= 2) && all(g <= P.dim.xyz - 3);
        int layer = layerOf(g, P.dim);
        bool band = hasParent && sub2 && layer >= 1 && layer <= 3;
        Params PP = P;
        if (feed) PP = loadParams(P.lvl.y);
        int3 gp = P.parent.xyz + (g >> 1);
        uint gpi = uint(PP.lvl.x) + cellIndex(gp, PP.dim);
        if (covered(P, g)) {
            // Idle: forward the macro the child left here (one parent step old) to the grandparent.
            if (feed) { float4 mm = mIn[gi]; if ((flags & 2) != 0) mOut[gpi] = mm; else mIn[gpi] = mm; }
        } else {
            float2 gc = geo[gi];
            if (gc.x <= 0.0) {
                // Solid: inactive (its slots carry the bounce-back populations of its fluid neighbours).
                float4 mm = float4(wallVelocity(P, asint(gc.y), float3(g)), -1.0);
                if (lastStep) mOut[gi] = mm;
                if (feed) { if ((flags & 2) != 0) mOut[gpi] = mm; else mIn[gpi] = mm; }
                if (band) aux[uint(asint(P.shift.w)) + bandIndex(g, P.dim) + 3u] = -1.0;
            } else if (hasParent && onBoundary(g, P.dim)) {
                // Ghost: post-collision set from the parent's records on the box surface. Space: a fine node halfway
                // between parent nodes (odd coordinate, always along the face) takes the 4-point cubic midpoint
                // weights (-1, 9, 9, -1)/16 of the parent nodes on that face line, linear where the face ends; time:
                // the first fine substep takes the mean of the parent's last two records.
                int3 s = (P.dim.xyz + 1) / 2;
                int3 odd = g & 1, lo = g >> 1;
                uint sc = surfCount(s);
                int latest = (flags >> 2) & 1;
                float r[REC];
                for (int c = 0; c < REC; c++) r[c] = 0.0;
                int3 n0, n1;     // stencil offsets per axis (inclusive)
                bool cub[3];
                for (int a = 0; a < 3; a++) {
                    cub[a] = odd[a] != 0 && lo[a] >= 1 && lo[a] + 2 <= s[a] - 1;
                    n0[a] = odd[a] == 0 ? 0 : (cub[a] ? -1 : 0);
                    n1[a] = odd[a] == 0 ? 0 : (cub[a] ? 2 : 1);
                }
                for (int oz = n0.z; oz <= n1.z; oz++)
                    for (int oy = n0.y; oy <= n1.y; oy++)
                        for (int ox = n0.x; ox <= n1.x; ox++) {
                            int3 o = int3(ox, oy, oz);
                            float w = 1.0;
                            for (int a = 0; a < 3; a++)
                                if (odd[a] != 0) w *= cub[a] ? ((o[a] == 0 || o[a] == 1) ? 0.5625 : -0.0625) : 0.5;
                            uint si = surfIndex(lo + o, s);
                            uint oL = uint(P.parent.w) + (uint(latest) * sc + si) * uint(REC);
                            uint oP = uint(P.parent.w) + (uint(1 - latest) * sc + si) * uint(REC);
                            for (int e = 0; e < REC; e++) r[e] += w * (sub2 ? aux[oL + uint(e)] : 0.5 * (aux[oL + uint(e)] + aux[oP + uint(e)]));
                        }
                float3 u = float3(r[0], r[1], r[2]);
                float rho = r[3];
                float tauC = max(r[10], 0.5005);
                float tauF = 2.0 * (tauC - 0.5) + 0.5;
                float k = tauF / (2.0 * tauC);
                float post[Q];
                for (int i = 0; i < Q; i++) post[i] = feq(i, rho, u) + (1.0 - 1.0 / tauF) * fneq(i, k * r[4], k * r[5], k * r[6], k * r[7], k * r[8], k * r[9]);
                storeSet(G, g, idx, t, post);
                mOut[gi] = float4(u, rho);
            } else if (!hasParent && onBoundary(g, P.dim)) {
                float rb; float3 ub;
                outerFace(P, g, gi, rb, ub);
                float post[Q];
                for (int i = 0; i < Q; i++) post[i] = feq(i, rb, ub);
                storeSet(G, g, idx, t, post);
                mOut[gi] = float4(ub, rb);
            } else {
                // Interior: all neighbours are in the box. Esoteric-pull load of the incoming populations.
                float3 uF = P.uFar.xyz;
                float fl[Q];
                fl[0] = ldF(G, 0, 0, idx);
                for (int k = 1; k < Q; k += 2) {
                    fl[k] = ldF(G, t != 0 ? k : k + 1, k, idx);
                    fl[k + 1] = ldF(G, t != 0 ? k + 1 : k, k + 1, cellIndex(g + C[k], P.dim));
                }
                // Log-law wall model (slip velocity) for under-resolved boundary layers, on nodes within 1.5 cells of a
                // wall: from the previous step's velocity, u_tau solves u_t / u_tau = ln(E y+) / kappa (kappa 0.41,
                // E 9.8). In the log region (y+ > 11) the wall links bounce back toward a tangential slip velocity
                // u_s = u_t - u_tau / kappa (the wall intercept of the log-law slope at y) and the node's viscosity is
                // kappa u_tau y, so the wall stress is rho u_tau^2 and the profile has the log-law slope, instead of a
                // no-slip ramp over one cell (a far too thick layer that separates early). Below y+ = 11 the node is
                // in the viscous sublayer: no slip, molecular viscosity. Only where the wall normal is well defined
                // (|grad d| within 20 % of 1; not near a thin trailing edge or a corner, where two walls meet).
                float3 slip = float3(0.0, 0.0, 0.0);
                float nuWall = -1.0;
                if ((asint(P.misc.y) & 4) != 0 && gc.x < 1.5) {
                    uint lb = uint(P.lvl.x);
                    float3 nrm = float3(geo[lb + cellIndex(g + int3(1, 0, 0), P.dim)].x - geo[lb + cellIndex(g - int3(1, 0, 0), P.dim)].x,
                                        geo[lb + cellIndex(g + int3(0, 1, 0), P.dim)].x - geo[lb + cellIndex(g - int3(0, 1, 0), P.dim)].x,
                                        geo[lb + cellIndex(g + int3(0, 0, 1), P.dim)].x - geo[lb + cellIndex(g - int3(0, 0, 1), P.dim)].x);
                    float ln = length(nrm);
                    float nu = (P.relax.y - 0.5) / 3.0;
                    float4 mp = mIn[gi];
                    if (ln > 1.6 && ln < 2.4 && nu > 0.0 && mp.w > 0.0) {   // central difference over 2 cells: |grad d| ~ ln / 2
                        nrm /= ln;
                        float y = max(gc.x, 0.05);
                        float3 ur = mp.xyz - wallVelocity(P, asint(gc.y), float3(g) - nrm * y);
                        float3 utv = ur - nrm * dot(nrm, ur);
                        float ut = length(utv);
                        float utau = sqrt(nu * ut / y);
                        nuWall = nu;
                        if (ut > 1e-7 && utau * y / nu > 11.0) {
                            for (int it = 0; it < 4; it++) utau = 0.41 * ut / log(max(9.8 * y * utau / nu, 1.5));
                            nuWall = max(0.41 * utau * y, WALL_NU_MIN);
                            slip = utv * (max(ut - utau * utau * y / nuWall, 0.0) / ut);
                        }
                    }
                }
                uint wslot = 0xFFFFFFFFu;
                uint wb = 0u;
                if (gc.x < 2.0) {
                    wslot = links[linkBase(P) + uint(LW) * uint(N) + idx];
                    bool hs = wslot != 0xFFFFFFFFu;
                    wb = uint(P.childHi.w) + (hs ? wslot : 0u) * uint(Q);
                    float pp[Q];
                    for (int i = 0; i < Q; i++) pp[i] = hs ? aux[wb + uint(i)] : 0.0;
                    for (int i = 1; i < Q; i++) {
                        int3 s = g - C[i];
                        uint code = linkCode(P, i, idx);
                        float q; int pid;
                        if (code == 0u) {
                            float2 gs = geo[uint(P.lvl.x) + cellIndex(s, P.dim)];
                            if (gs.x > 0.0) continue;
                            q = 0.5; pid = asint(gs.y);               // solid neighbour without a sampled crossing (fallback)
                        } else {
                            q = float(code & 255u) / 255.0;
                            uint pc = code >> 8; pid = pc == 255u ? -2 : int(pc) - 1;
                        }
                        q = clamp(q, 0.02, 0.98);
                        // Link crosses a wall: interpolated (Bouzidi) bounce-back of the population that left x toward
                        // the wall last step (f*_o(x)). From the wall slot when the cell has one (exact); otherwise from
                        // the esoteric slot the cell behind the wall would load, which only it touches (exact when that
                        // cell is solid; with no wall slot the q >= 0.5 branch degrades to simple bounce-back).
                        int o = OPP(i);
                        float fo, fi;
                        if (hs) { fo = pp[o]; fi = pp[i]; }
                        else {
                            fo = (i & 1) != 0 ? ldF(G, t != 0 ? i + 1 : i, o, idx) : ldF(G, t != 0 ? i - 1 : i, o, cellIndex(s, P.dim));
                            fi = fo;
                        }
                        float3 ci = float3(C[i]);
                        float3 wp = float3(g) - q * ci;
                        float3 uw = wallVelocity(P, pid, wp);
                        float mw = 6.0 * W[i] * dot(ci, uw + slip);
                        float v;
                        if (q < 0.5) {
                            uint x2 = uint(P.lvl.x) + cellIndex(g + C[i], P.dim);
                            if (geo[x2].x > 0.0 && linkCode(P, o, idx) == 0u)
                                v = 2.0 * q * fo + (1.0 - 2.0 * q) * fl[o] + mw;   // fl[o] = f*_o(x + c_i), streamed in
                            else v = fo + mw;
                        } else {
                            v = fo / (2.0 * q) + (2.0 * q - 1.0) / (2.0 * q) * fi + mw / (2.0 * q);
                        }
                        fl[i] = v;
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
                float rho = 0.0; float3 m = float3(0.0, 0.0, 0.0);
                for (int i = 0; i < Q; i++) { rho += fl[i]; m += fl[i] * float3(C[i]); }
                // Body force: frame acceleration + actuator disks (thrust + swirl).
                float3 F = rho * P.accel.xyz;
                float3 x = float3(g);
                int rb0 = D.i.z * LEVEL_STRIDE + ROTOR_OFFSET;
                for (int r = 0; r < P.mode.w; r++) {
                    float4 c = scene[rb0 + 3 * r], ax = scene[rb0 + 3 * r + 1], sw = scene[rb0 + 3 * r + 2];
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
                    float nq = fl[i] - fe[i]; float3 cc = float3(C[i]);
                    pxx += nq * cc.x * cc.x; pyy += nq * cc.y * cc.y; pzz += nq * cc.z * cc.z;
                    pxy += nq * cc.x * cc.y; pxz += nq * cc.x * cc.z; pyz += nq * cc.y * cc.z;
                }
                float tau = tau0;
                if (P.mode.y == 1) {   // Smagorinsky (Hou et al. 1996), Delta = 1 cell, van Driest-style wall damping
                    float Qn = sqrt(pxx * pxx + pyy * pyy + pzz * pzz + 2.0 * (pxy * pxy + pxz * pxz + pyz * pyz));
                    float cs2 = P.relax.z * P.relax.z;
                    float damp = P.accel.w > 0.0 ? 1.0 - exp(-max(gc.x, 0.0) / P.accel.w) : 1.0;
                    cs2 *= damp * damp;
                    tau = 0.5 * (tau0 + sqrt(tau0 * tau0 + 18.0 * 1.41421356 * cs2 * Qn / max(rho, 1e-6)));
                } else if (P.mode.y == 2) {   // WALE (Nicoud & Ducros 1999) from the previous step's velocity field
                    float Gr[3][3];   // Gr[a][b] = du_a / dx_b
                    for (int b = 0; b < 3; b++) {
                        int3 e = int3(b == 0 ? 1 : 0, b == 1 ? 1 : 0, b == 2 ? 1 : 0);
                        float3 du = 0.5 * (mIn[uint(P.lvl.x) + cellIndex(g + e, P.dim)].xyz - mIn[uint(P.lvl.x) + cellIndex(g - e, P.dim)].xyz);
                        Gr[0][b] = du.x; Gr[1][b] = du.y; Gr[2][b] = du.z;
                    }
                    float g2[3][3];
                    for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) g2[a][b] = Gr[a][0] * Gr[0][b] + Gr[a][1] * Gr[1][b] + Gr[a][2] * Gr[2][b];
                    float tr = (g2[0][0] + g2[1][1] + g2[2][2]) / 3.0;
                    float SS = 0.0, SdSd = 0.0;
                    for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) {
                        float S = 0.5 * (Gr[a][b] + Gr[b][a]);
                        float Sd = 0.5 * (g2[a][b] + g2[b][a]) - (a == b ? tr : 0.0);
                        SS += S * S; SdSd += Sd * Sd;
                    }
                    float cw2 = P.relax.w * P.relax.w;
                    float nut = cw2 * pow(SdSd, 1.5) / (pow(SS, 2.5) + pow(SdSd, 1.25) + 1e-20);
                    tau = tau0 + 3.0 * nut;
                }
                if (nuWall >= 0.0) tau = min(0.5 + 3.0 * nuWall, 1.0);   // wall model: replaces the LES viscosity
                tau = max(tau, 0.5005);
                float om = 1.0 / tau;
                // Level 0: sponge layers at the outer faces, absorbing what reaches them (the impulsive start's sound
                // waves included). Inflow and lateral: toward the far-field state (rho0, u_inf); outflow: density
                // toward rho0 only (the wake leaves with its velocity), which also pins the pressure level.
                float sigU = 0.0, sigP = 0.0;
                if (P.mode2.y > 0) {
                    int inM = int(P.uFar.w), outM = int(P.misc.w);
                    int dU = 1 << 20, dP = 1 << 20;
                    for (int a = 0; a < 3; a++) {
                        int lo = g[a], hi = P.dim[a] - 1 - g[a];
                        if ((outM & (1 << (2 * a))) != 0) dP = min(dP, lo); else dU = min(dU, lo);
                        if ((outM & (1 << (2 * a + 1))) != 0) dP = min(dP, hi); else dU = min(dU, hi);
                    }
                    if (dU < P.mode2.y) { float s = 1.0 - float(dU) / float(P.mode2.y); sigU = P.misc.x * s * s; }
                    if (dP < P.mode2.y) { float s = 1.0 - float(dP) / float(P.mode2.y); sigP = P.misc.x * s * s; }
                }
                float post[Q];
                for (int i = 0; i < Q; i++) {
                    float3 cc = float3(C[i]);
                    float cu = dot(cc, u);
                    float Si = (1.0 - 0.5 * om) * W[i] * dot(3.0 * (cc - u) + 9.0 * cu * cc, F);
                    float pv;
                    if (P.mode.x == 2) {   // regularized: f_neq rebuilt from its 2nd-order Hermite projection
                        pv = fe[i] + (1.0 - om) * fneq(i, pxx, pyy, pzz, pxy, pxz, pyz) + Si;
                    } else if (P.mode.x == 1) {   // MRT in the Hermite basis: stress modes relax at omega, ghost modes at 1.2
                        float f1 = fneq(i, pxx, pyy, pzz, pxy, pxz, pyz);
                        pv = fe[i] + (1.0 - om) * f1 + (1.0 - 1.2) * (fl[i] - fe[i] - f1) + Si;
                    } else {
                        pv = fl[i] - om * (fl[i] - fe[i]) + Si;
                    }
                    if (sigU > 0.0) pv += sigU * (feq(i, 1.0, uF) - feq(i, rho, u));
                    if (sigP > 0.0) pv += sigP * (feq(i, 1.0, u) - feq(i, rho, u));
                    post[i] = pv;
                }
                storeSet(G, g, idx, t, post);
                if (wslot != 0xFFFFFFFFu) for (int i = 0; i < Q; i++) aux[wb + uint(i)] = post[i];
                // Coarse -> fine: records for the child's ghosts.
                if (onChildSurface(P, g)) writeRecord(P, g, t, u, rho, pxx, pyy, pzz, pxy, pxz, pyz, tau);
                // Fine -> coarse: macro, and the band records for lbmRestrict.
                if (feed) { if ((flags & 2) != 0) mOut[gpi] = float4(u, rho); else mIn[gpi] = float4(u, rho); }
                if (band) {
                    uint o = uint(asint(P.shift.w)) + bandIndex(g, P.dim);
                    aux[o] = u.x; aux[o + 1] = u.y; aux[o + 2] = u.z; aux[o + 3] = rho;
                    aux[o + 4] = pxx; aux[o + 5] = pyy; aux[o + 6] = pzz; aux[o + 7] = pxy; aux[o + 8] = pxz; aux[o + 9] = pyz;
                    aux[o + 10] = tau; aux[o + 11] = 0.0;
                }
                // Macro: every cell on the last step; otherwise only what the next step reads (level-0 outer-face
                // neighbours, wall-model nodes, or everything for WALE).
                int face = min(min(min(g.x, P.dim.x - 1 - g.x), min(g.y, P.dim.y - 1 - g.y)), min(g.z, P.dim.z - 1 - g.z));
                if (lastStep || P.mode.y == 2 || (!hasParent && face <= 1) || gc.x < 1.5) mOut[gi] = float4(u, rho);
                ma = length(u) * 1.7320508;
                if (isnan(ma) || isnan(rho)) { bad = true; ma = 0.0; }
            }
        }
    }
    // Lattice-Mach maximum and NaN flag: one atomic per wave.
    uint maBits = WaveActiveMax(asuint(ma));
    bool anyBad = WaveActiveAnyTrue(bad);
    if (WaveIsFirstLane()) {
        if (anyBad) red[1] = 1u;
        if (maBits != 0u) { uint o; InterlockedMax(red[0], maBits, o); }
    }
    // Forces: one wave-wide sum when every contributing lane hit the same part (the common case), else per-lane atomics.
    int mx = WaveActiveMax(curPart);
    bool same = WaveActiveAllTrue(curPart < 0 || curPart == mx);
    if (same) {
        if (mx >= 0) {
            float3 sF = WaveActiveSum(aF), sT = WaveActiveSum(aT);
            if (WaveIsFirstLane()) flushPart(mx, sF, sT);
        }
    } else if (curPart >= 0) flushPart(curPart, aF, aT);
}

/// Fine -> coarse restriction for fine level D.i.z after its second substep: one thread per node of the fine layer 2
/// (D.i.x = their count); even nodes coincide with the parent's restricted layer and write that parent node's
/// post-collision set at parity D.i.w (the parent's latest step): equilibrium at the coincident node's (rho, u) plus
/// the regularized non-equilibrium of the (1/4, 1/2, 1/4)^3-filtered Pi_neq and tau of the 27 fine neighbours (band
/// records, layers 1..3), rescaled Pi_c = Pi_f 2 tau_c / tau_f with tau_c - 1/2 = (tau_f - 1/2) / 2.
[shader("compute")][numthreads(64, 1, 1)]
void lbmRestrict(uint3 gid : SV_DispatchThreadID) {
    if (int(gid.x) >= D.i.x) return;
    Params P = loadParams(D.i.z);
    int3 g = surfCoord(gid.x, P.dim.xyz - 4) + 2;
    if (any((g & 1) != 0)) return;
    uint bb = uint(asint(P.shift.w));
    uint oc = bb + bandIndex(g, P.dim);
    float rho = aux[oc + 3];
    if (!(rho > 0.0)) return;   // solid (ground): the parent node is solid too
    float3 u = float3(aux[oc], aux[oc + 1], aux[oc + 2]);
    float pi[6] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
    float tau = 0.0, wsum = 0.0;
    for (int dz = -1; dz <= 1; dz++)
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) {
                int3 d = int3(dx, dy, dz);
                uint o = bb + bandIndex(g + d, P.dim);
                if (!(aux[o + 3] > 0.0)) continue;
                float w = (dx == 0 ? 0.5 : 0.25) * (dy == 0 ? 0.5 : 0.25) * (dz == 0 ? 0.5 : 0.25);
                for (int c = 0; c < 6; c++) pi[c] += w * aux[o + 4 + uint(c)];
                tau += w * aux[o + 10];
                wsum += w;
            }
    for (int c = 0; c < 6; c++) pi[c] /= wsum;
    tau = max(tau / wsum, 0.5005);
    Params PP = loadParams(P.lvl.y);
    float tauC = 0.5 * (tau - 0.5) + 0.5;
    if (PP.mode.y == 1) {
        // Smagorinsky on the parent: its eddy viscosity scales with its own (twice larger) filter width, so the
        // restricted node relaxes like its parent neighbours: nu_t,c = (Cs dx_c)^2 |S| with |S|_c = 2 |S|_f.
        float pn = sqrt(pi[0] * pi[0] + pi[1] * pi[1] + pi[2] * pi[2] + 2.0 * (pi[3] * pi[3] + pi[4] * pi[4] + pi[5] * pi[5]));
        float sF = 3.0 * 1.41421356 * pn / (2.0 * rho * tau);
        tauC = max(tauC, PP.relax.y + 3.0 * PP.relax.z * PP.relax.z * 2.0 * sF);
    }
    float kk = 2.0 * tauC / tau;
    int3 gp = P.parent.xyz + (g >> 1);
    float pc[Q];
    for (int i = 0; i < Q; i++) pc[i] = feq(i, rho, u) + (1.0 - 1.0 / tauC) * fneq(i, kk * pi[0], kk * pi[1], kk * pi[2], kk * pi[3], kk * pi[4], kk * pi[5]);
    storeSet(gridOf(PP), gp, cellIndex(gp, PP.dim), D.i.w & 1, pc);
}

// ---------------------------------------------------------------- diagnostics
/// Sum of rho and fluid-cell count over level 0's macro (mIn = its latest; idle nodes hold the finer levels' values).
[shader("compute")][numthreads(128, 1, 1)]
void lbmMass(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(0);
    float r = 0.0, c = 0.0;
    if (int(gid.x) < P.dim.w) { float4 m = mIn[gid.x]; if (m.w > 0.0) { r = m.w; c = 1.0; } }
    r = WaveActiveSum(r); uint n = WaveActiveCountBits(c > 0.0);
    if (WaveIsFirstLane()) { atomicAddFixed(4, r); uint o; InterlockedAdd(red[2], n, o); }
}

/// Flow velocity at each sample point (grid coordinates of level D.i.z in scene[layout.y + i]; mIn = that level's
/// latest macro): nearest fluid node, searching outward along the axes up to 4 cells.
[shader("compute")][numthreads(64, 1, 1)]
void lbmSample(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(D.i.z);
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
            float4 m = mIn[uint(P.lvl.x) + cellIndex(c, P.dim)];
            if (m.w > 0.0) { found = m; done = true; }
        }
    }
    uint o = uint(P.layout.w + 4 * i);
    red[o] = asuint(found.x); red[o + 1] = asuint(found.y); red[o + 2] = asuint(found.z); red[o + 3] = asuint(found.w);
}

// ---------------------------------------------------------------- visualisation
/// Finest level whose interior contains p (level-0 grid coordinates): level, nearest node. D.j.x = bit l set when
/// level l's latest macro is in mOut (else mIn), D.j.y = level count.
int findLevel(float3 p0, out int3 node) {
    node = int3(0, 0, 0);
    for (int l = D.j.y - 1; l >= 0; l--) {
        int b = l * LEVEL_STRIDE;
        int4 dim = asint(scene[b]);
        float4 view = scene[b + 15];
        int3 c = int3(round((p0 - view.xyz) * view.w));
        bool ok = l > 0 ? (all(c >= 1) && all(c <= dim.xyz - 2)) : inside(c, dim);
        if (ok) { node = c; return l; }
    }
    return -1;
}
float4 levelMacro(int l, int3 c) {
    int b = l * LEVEL_STRIDE;
    int4 dim = asint(scene[b]);
    uint gi = uint(asint(scene[b + 10]).x) + cellIndex(clamp(c, int3(0, 0, 0), dim.xyz - 1), dim);
    return ((D.j.x >> l) & 1) != 0 ? mOut[gi] : mIn[gi];
}

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

/// Slice through the domain into links (u7) as RGBA8: D.i = (axis, width, height, field), D.f = (top, frame vel),
/// D.j = (latest mask, level count, texels per level-0 cell, layer in level-0 cells * 256). axis 0 -> (y,z) plane,
/// 1 -> (x,z), 2 -> (x,y). field 0 speed, 1 pressure, 2 vorticity. Each texel shows the finest level there.
/// The slice's max raw value goes to red[6] (non-negative float bits order like uints) for the CPU auto-range.
[shader("compute")][numthreads(16, 16, 1)]
void lbmSlice(uint3 gid : SV_DispatchThreadID) {
    int axis = D.i.x, width = D.i.y, height = D.i.z, field = D.i.w;
    int2 t = int2(gid.xy);
    if (t.x >= width || t.y >= height) return;
    uint px = uint(t.y * width + t.x);
    float rs = 1.0 / float(D.j.z), layer = float(D.j.w) / 256.0;
    float3 p0 = axis == 0 ? float3(layer, t.x * rs, t.y * rs) : (axis == 1 ? float3(t.x * rs, layer, t.y * rs) : float3(t.x * rs, t.y * rs, layer));
    int3 c;
    int l = findLevel(p0, c);
    if (l < 0) { links[px] = 0u; return; }
    float4 m = levelMacro(l, c);
    if (m.w < 0.0) { links[px] = packRGBA8(float4(0.08, 0.08, 0.09, 1.0)); return; }
    float r, v;
    float top = max(D.f.x, 1e-9);
    if (field == 0) { r = length(m.xyz + D.f.yzw); v = r / top; }
    else if (field == 1) { float dp = (m.w - 1.0) / 3.0; r = abs(dp); v = 0.5 + 0.5 * dp / top; }
    else {
        float3 d[3];
        for (int b = 0; b < 3; b++) {
            int3 e = int3(b == 0 ? 1 : 0, b == 1 ? 1 : 0, b == 2 ? 1 : 0);
            d[b] = 0.5 * (levelMacro(l, c + e).xyz - levelMacro(l, c - e).xyz);
        }
        float3 w = float3(d[1].z - d[2].y, d[2].x - d[0].z, d[0].y - d[1].x);
        r = length(w); v = r / top;
    }
    if (!isnan(r) && !isinf(r)) { uint o; InterlockedMax(red[6], asuint(r), o); }
    links[px] = packRGBA8(float4(turbo(clamp(v, 0.0, 1.0)), 0.85));
}

/// Massless tracers (level-0 grid coordinates, 4 floats each in u3) advected with the local lattice velocity of the
/// finest level there (lattice velocities are equal on every level) for D.f.x level-0 steps; respawn upstream on exit.
/// D.i.x = count; macro buffers and D.j as in lbmSlice.
[shader("compute")][numthreads(128, 1, 1)]
void lbmParticles(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams(0);
    if (int(gid.x) >= D.i.x) return;
    float steps = D.f.x;
    uint o = gid.x * 4u;
    float4 q = float4(aux[o], aux[o + 1], aux[o + 2], aux[o + 3]);
    int3 c;
    int l = findLevel(q.xyz, c);
    float4 m = l >= 0 ? levelMacro(l, c) : float4(0.0, 0.0, 0.0, -1.0);
    if (m.w > 0.0) { q.xyz += m.xyz * steps; q.w += steps; }
    int3 g = int3(round(q.xyz));
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
    aux[o] = q.x; aux[o + 1] = q.y; aux[o + 2] = q.z; aux[o + 3] = q.w;
}
