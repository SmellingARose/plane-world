// Lattice-Boltzmann CFD kernels (descended from Sources/Flow/LBMShaders.swift, the Metal source of the Swift solver).
// Included by lbm19.slang / lbm27.slang (fp32 population storage) and lbm19h.slang / lbm27h.slang (fp16 storage,
// FP16 defined), which define Q (velocity set) before including this file.
//
// Populations: ONE buffer, SoA (slot k of cell n at k*N + n), esoteric-pull streaming (Lehmann 2022): every LBM step
// is one fused kernel (lbmStep) in which each cell loads its incoming populations from, and stores its post-collision
// populations back to, the same 2(Q-1)+1 slots (its own and its +c_k neighbours'), alternating with the step parity.
// No second population buffer, no separate stream pass. Storage is (f_i - w_i) * FSCALE, as fp16 (FSCALE 2^15) or
// fp32 (FSCALE 1); arithmetic is fp32. Lattice units throughout (dx = dt = 1, rho0 = 1, cs^2 = 1/3).
//
// Binding model (pw/compute.h): b0 = per-dispatch constants, u1..u8 = storage buffers. Slots are shared by role:
//   u1 scene  float4: [0..9] params, [10..57] rotors (3 float4 each), parts (8 float4 each), sample points
//   u2 fS     FT    : populations (single buffer, esoteric pull)
//   u3 wallF  float : previous post-collision populations of near-wall cells (Q per wall slot; exact Bouzidi)
//   u4 mOut   float4: macro (u, rho; rho < 0 = solid) written by lbmStep | particles: tracer positions
//   u5 mIn    float4: previous macro (outlet / WALE / slice / particles / mass / sample) | voxelize: part SDF grids
//                     (float data packed 4 per float4)
//   u6 geo    float2: (signed distance in cells, part id bits: -1 none, -2 ground, k = part slot)
//   u7 links  uint  : wall crossings, two 16-bit link codes per uint ([i/2]*N + cell), then the wall slot of the
//                     cell ([LW*N + cell], 0xFFFFFFFF = none) | slice: RGBA8 pixels
//   u8 red    uint  : reductions: [0] max lattice Mach bits, [1] NaN flag, [2] fluid cells, [4..5] sum rho,
//                     [6] slice range bits, [7] wall-slot counter, [8 + 12k] force/torque of part k
//                     (6 x 64-bit fixed point), then 4 float bits per sample point
// Float atomics are 64-bit fixed-point integer atomics after a wave (SIMD-group) reduction (D3D12 SM 6.0 has no
// float atomics; Metal only has a weak compare-exchange).

struct Dispatch {
    int4 i;      // kernel-specific integers
    float4 f;    // kernel-specific floats
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
RWStructuredBuffer<float> wallF : register(u3);
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
    float4 misc;     // x sponge strength, y accuracy flags (bit 0: inflate thin parts only, bit 1: refined crossings,
                     // bit 2: log-law wall model), z dt (s), w unused
    int4 layout;     // x part base (float4 index), y sample base, z sample count, w reduction offset of the samples
};
static const int ROTOR_BASE = 10;
static const int PART_STRIDE = 8;

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

float feq(int i, float rho, float3 u) {
    float cu = dot(float3(C[i]), u);
    return W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * dot(u, u));
}

// Population slot access. Slot k always holds a population of pair (k, OPP(k)), whose weights are equal, so the
// stored deviation is taken from W[k].
float ldF(int k, uint cell, int N) { return float(fS[uint(k) * uint(N) + cell]) * (1.0 / FSCALE) + W[k]; }
void stF(int k, uint cell, int N, float v) { fS[uint(k) * uint(N) + cell] = FT((v - W[k]) * FSCALE); }

/// Esoteric-pull store of a full post-collision set at step parity t (out-of-domain neighbour slots are skipped:
/// only face cells, which never load, would read them).
void storeSet(int3 g, uint n, int N, int4 dim, int t, float post[Q]) {
    stF(0, n, N, post[0]);
    for (int k = 1; k < Q; k += 2) {
        int3 j = g + C[k];
        if (inside(j, dim)) stF(t != 0 ? k + 1 : k, cellIndex(j, dim), N, post[k]);
        stF(t != 0 ? k : k + 1, n, N, post[k + 1]);
    }
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

/// Wall velocity (lattice) of the owner of a wall point g (part slot pid; -2 = ground).
float3 wallVelocity(Params P, int pid, float3 g) {
    if (pid == -2) return P.ground.yzw;
    if (pid < 0) return float3(0.0, 0.0, 0.0);
    GPart p = loadPart(P, pid);
    float3 r = g - (P.center.xyz + p.pos.xyz / P.center.w);
    return p.linVel.xyz + cross(p.angVel.xyz, r);
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
/// Per node: signed distance (cells) and nearest part; for near-wall fluid nodes the wall crossing of every link,
/// sampled at 1/8 steps along x -> x - c_i (sheets thinner than a cell still cut the link). Link code: 0 = no wall,
/// else low byte q*255 (1..255), high byte part slot + 1 (255 = ground). With accuracy flag bit 1 the bracketing
/// 1/8 interval is refined by two secant (regula falsi) iterations instead of one linear interpolation.
/// D.i.x = index of the next LBM step (its parity selects the esoteric slots), D.i.y = wall-slot capacity.
/// Also: (a) cells uncovered by a moving part since the last update get equilibrium populations at the wall velocity
/// (written to the slots their last post-collision set would occupy); (b) every near-wall fluid cell is given a wall
/// slot and its last post-collision set is copied there, so lbmStep can do exact interpolated bounce-back even across
/// sheets thinner than a cell (where the neighbour behind the wall is fluid and owns the slots esoteric pull would
/// otherwise reuse).
[shader("compute")][numthreads(64, 1, 1)]
void lbmVoxelize(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int N = P.dim.w;
    int n = int(gid.x);
    if (n >= N) return;
    int3 g = cellCoord(n, P.dim);
    uint idx = uint(n);
    float dx = P.center.w;
    float3 pm = (float3(g) - P.center.xyz) * dx;
    int bp;
    float s0 = sceneSDF(P, pm, bp);
    float2 old = geo[idx];
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
    // Populations: the next step has parity t, so the last post-collision set was stored with parity 1 - t.
    int t = D.i.x & 1;
    bool fresh = s0 > 0.0 && old.x <= 0.0;
    float post[Q];
    if (fresh) {
        float3 uw = wallVelocity(P, asint(old.y), float3(g));
        for (int i = 0; i < Q; i++) post[i] = feq(i, 1.0, uw);
        storeSet(g, idx, N, P.dim, 1 - t, post);
    }
    uint slot = 0xFFFFFFFFu;
    if (nearWall) {
        uint s;
        InterlockedAdd(red[7], 1u, s);
        if (s < uint(D.i.y)) {
            slot = s;
            if (!fresh) {
                post[0] = ldF(0, idx, N);
                for (int k = 1; k < Q; k += 2) {
                    int3 j = g + C[k];
                    post[k] = inside(j, P.dim) ? ldF(t != 0 ? k : k + 1, cellIndex(j, P.dim), N) : feq(k, 1.0, P.uFar.xyz);
                    post[k + 1] = ldF(t != 0 ? k + 1 : k, idx, N);
                }
            }
            for (int i = 0; i < Q; i++) wallF[slot * uint(Q) + uint(i)] = post[i];
        }
    }
    links[uint(LW) * uint(N) + idx] = slot;
}

// ---------------------------------------------------------------- init / rescale / clear
/// Far-field equilibrium everywhere (stored for the step D.i.x).
[shader("compute")][numthreads(64, 1, 1)]
void lbmInit(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int n = int(gid.x);
    if (n >= P.dim.w) return;
    float post[Q];
    for (int i = 0; i < Q; i++) post[i] = feq(i, 1.0, P.uFar.xyz);
    storeSet(cellCoord(n, P.dim), uint(n), P.dim.w, P.dim, 1 - (D.i.x & 1), post);
}

/// Changes the lattice time step by factor k (u -> k u): f = feq(rho, k u) + k (f - feq(rho, u)). k = D.f.x,
/// D.i.x = index of the next step. Each cell transforms the set it will load next step, in place (race free: every
/// slot is loaded by exactly one cell). Solid / face cells (whose sets are partly foreign) use the linearised form
/// f = w + k (f - w).
[shader("compute")][numthreads(64, 1, 1)]
void lbmRescale(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int n = int(gid.x);
    if (n >= P.dim.w) return;
    int N = P.dim.w;
    int t = D.i.x & 1;
    float k = D.f.x;
    int3 g = cellCoord(n, P.dim);
    uint sl[Q]; int sk[Q]; bool ok[Q];
    sl[0] = uint(n); sk[0] = 0; ok[0] = true;
    for (int i = 1; i < Q; i += 2) {
        int3 j = g + C[i];
        sl[i] = uint(n); sk[i] = t != 0 ? i : i + 1; ok[i] = true;
        ok[i + 1] = inside(j, P.dim);
        sl[i + 1] = ok[i + 1] ? cellIndex(j, P.dim) : 0u; sk[i + 1] = t != 0 ? i + 1 : i;
    }
    bool full = geo[uint(n)].x > 0.0;
    float fl[Q]; float rho = 0.0; float3 m = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < Q; i++) {
        full = full && ok[i];
        fl[i] = ok[i] ? ldF(sk[i], sl[i], N) : W[i];
        rho += fl[i]; m += fl[i] * float3(C[i]);
    }
    float3 u = m / max(rho, 1e-6);
    for (int i = 0; i < Q; i++) {
        if (!ok[i]) continue;
        float v = full ? feq(i, rho, k * u) + k * (fl[i] - feq(i, rho, u)) : W[i] + k * (fl[i] - W[i]);
        stF(sk[i], sl[i], N, v);
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

/// Esoteric-pull load + walls (interpolated bounce-back, momentum exchange) + collision + store, one cell per thread.
/// D.i.x = step index (parity), D.i.y = 1 when every cell must write its macro (last step of the update).
[shader("compute")][numthreads(64, 1, 1)]
void lbmStep(uint3 gid : SV_DispatchThreadID) {
    Params P = loadParams();
    int N = P.dim.w;
    int n = int(gid.x);
    int t = D.i.x & 1;
    bool lastStep = D.i.y != 0;
    int curPart = -1; float3 aF = float3(0.0, 0.0, 0.0), aT = float3(0.0, 0.0, 0.0);
    float ma = 0.0; bool bad = false;
    if (n < N) {
        uint idx = uint(n);
        int3 g = cellCoord(n, P.dim);
        float2 gc = geo[idx];
        if (gc.x <= 0.0) {
            // Solid: inactive (its slots carry the bounce-back populations of its fluid neighbours).
            if (lastStep) mOut[idx] = float4(wallVelocity(P, asint(gc.y), float3(g)), -1.0);
        } else {
            // Far field: inflow faces (bit set in uFar.w) are Dirichlet u_inf with a velocity sponge; all other faces
            // are open (zero-gradient) with a pressure-only sponge, so circulation / downwash can leave the domain.
            int mask = int(P.uFar.w);
            int dIn = 1 << 20, dOut = 1 << 20;
            for (int a = 0; a < 3; a++) {
                int lo = g[a], hi = P.dim[a] - 1 - g[a];
                if ((mask & (1 << (2 * a))) != 0) dIn = min(dIn, lo); else dOut = min(dOut, lo);
                if ((mask & (1 << (2 * a + 1))) != 0) dIn = min(dIn, hi); else dOut = min(dOut, hi);
            }
            float3 uF = P.uFar.xyz;
            float post[Q];
            if (dIn == 0 || dOut == 0) {
                float3 ub = uF;
                if (dIn != 0) {   // open face: equilibrium at rho0 and the inward neighbour's velocity (previous step)
                    int3 gi = clamp(g, int3(1, 1, 1), P.dim.xyz - 2);
                    float4 mi = mIn[cellIndex(gi, P.dim)];
                    ub = mi.w > 0.0 ? mi.xyz : uF;
                    float lu = length(ub); if (lu > 0.3) ub *= 0.3 / lu;
                }
                for (int i = 0; i < Q; i++) post[i] = feq(i, 1.0, ub);
                storeSet(g, idx, N, P.dim, t, post);
                mOut[idx] = float4(ub, 1.0);
            } else {
                // Interior: all neighbours are in the domain. Esoteric-pull load of the incoming populations.
                float fl[Q];
                fl[0] = ldF(0, idx, N);
                for (int k = 1; k < Q; k += 2) {
                    fl[k] = ldF(t != 0 ? k : k + 1, idx, N);
                    fl[k + 1] = ldF(t != 0 ? k + 1 : k, cellIndex(g + C[k], P.dim), N);
                }
                uint wslot = 0xFFFFFFFFu;
                if (gc.x < 2.0) {
                    wslot = links[uint(LW) * uint(N) + idx];
                    bool hs = wslot != 0xFFFFFFFFu;
                    float pp[Q];
                    for (int i = 0; i < Q; i++) pp[i] = hs ? wallF[wslot * uint(Q) + uint(i)] : 0.0;
                    for (int i = 1; i < Q; i++) {
                        int3 s = g - C[i];
                        uint code = linkCode(i, idx, N);
                        float q; int pid;
                        if (code == 0u) {
                            float2 gs = geo[cellIndex(s, P.dim)];
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
                            fo = (i & 1) != 0 ? ldF(t != 0 ? i + 1 : i, idx, N) : ldF(t != 0 ? i - 1 : i, cellIndex(s, P.dim), N);
                            fi = fo;
                        }
                        float3 ci = float3(C[i]);
                        float3 wp = float3(g) - q * ci;
                        float3 uw = wallVelocity(P, pid, wp);
                        float mw = 6.0 * W[i] * dot(ci, uw);
                        float v;
                        if (q < 0.5) {
                            uint x2 = cellIndex(g + C[i], P.dim);
                            if (geo[x2].x > 0.0 && linkCode(o, idx, N) == 0u)
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
                    float G[3][3];   // G[a][b] = du_a / dx_b
                    for (int b = 0; b < 3; b++) {
                        int3 e = int3(b == 0 ? 1 : 0, b == 1 ? 1 : 0, b == 2 ? 1 : 0);
                        float3 du = 0.5 * (mIn[cellIndex(g + e, P.dim)].xyz - mIn[cellIndex(g - e, P.dim)].xyz);
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
                if ((asint(P.misc.y) & 4) != 0 && gc.x < 1.5) {
                    // Log-law wall model for under-resolved boundary layers: the first fluid cell gets the eddy
                    // viscosity nu_w = u_tau^2 y / u_t that makes its bounce-back wall stress equal rho u_tau^2, with
                    // u_tau from u_t / u_tau = ln(E y+) / kappa (kappa 0.41, E 9.8); only in the log region (y+ > 11).
                    float3 nrm = float3(geo[cellIndex(g + int3(1, 0, 0), P.dim)].x - geo[cellIndex(g - int3(1, 0, 0), P.dim)].x,
                                        geo[cellIndex(g + int3(0, 1, 0), P.dim)].x - geo[cellIndex(g - int3(0, 1, 0), P.dim)].x,
                                        geo[cellIndex(g + int3(0, 0, 1), P.dim)].x - geo[cellIndex(g - int3(0, 0, 1), P.dim)].x);
                    float ln = length(nrm);
                    float nu = (tau0 - 0.5) / 3.0;
                    if (ln > 1e-6 && nu > 0.0) {
                        nrm /= ln;
                        float y = max(gc.x, 0.05);
                        float3 ur = u - wallVelocity(P, asint(gc.y), float3(g) - nrm * y);
                        float ut = length(ur - nrm * dot(nrm, ur));
                        float utau = sqrt(nu * ut / y);
                        if (ut > 1e-7 && utau * y / nu > 11.0) {
                            for (int it = 0; it < 4; it++) utau = 0.41 * ut / log(max(9.8 * y * utau / nu, 1.5));
                            float nuw = utau * utau * y / ut;
                            tau = max(tau, min(0.5 + 3.0 * nuw, 1.0));
                        }
                    }
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
                    float pv;
                    if (P.mode.x == 2) {   // regularized: f_neq rebuilt from its 2nd-order Hermite projection
                        float qxx = cc.x * cc.x - 1.0 / 3.0, qyy = cc.y * cc.y - 1.0 / 3.0, qzz = cc.z * cc.z - 1.0 / 3.0;
                        float f1 = 4.5 * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0 * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
                        pv = fe[i] + (1.0 - om) * f1 + Si;
                    } else if (P.mode.x == 1) {   // MRT in the Hermite basis: stress modes relax at omega, ghost modes at 1.2
                        float qxx = cc.x * cc.x - 1.0 / 3.0, qyy = cc.y * cc.y - 1.0 / 3.0, qzz = cc.z * cc.z - 1.0 / 3.0;
                        float f1 = 4.5 * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0 * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
                        pv = fe[i] + (1.0 - om) * f1 + (1.0 - 1.2) * (fl[i] - fe[i] - f1) + Si;
                    } else {
                        pv = fl[i] - om * (fl[i] - fe[i]) + Si;
                    }
                    if (sig > 0.0) pv += sig * (feq(i, 1.0, uF) - pv);
                    if (sigP > 0.0) pv += sigP * (feq(i, 1.0, u) - feq(i, rho, u));   // relax density only
                    post[i] = pv;
                }
                storeSet(g, idx, N, P.dim, t, post);
                if (wslot != 0xFFFFFFFFu) for (int i = 0; i < Q; i++) wallF[wslot * uint(Q) + uint(i)] = post[i];
                // Macro: every cell on the last step; otherwise only what the next step reads (open-face neighbours,
                // or everything for WALE).
                int face = min(min(min(g.x, P.dim.x - 1 - g.x), min(g.y, P.dim.y - 1 - g.y)), min(g.z, P.dim.z - 1 - g.z));
                if (lastStep || P.mode.y == 2 || face <= 1) mOut[idx] = float4(u, rho);
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
