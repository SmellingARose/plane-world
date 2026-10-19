// Finite-volume incompressible Navier–Stokes kernels (pw/flow/ns.h, docs/CFD_NS.md).
//
// Grid: staggered MAC. Interior cells i in [0, n) per axis are stored with 2 ghost layers: storage coordinate
// g = i + 2, storage dims S = n + 4, storage index s = g.x + S.x (g.y + S.y g.z). Velocity component c at storage s is
// the face on the LOW side of cell s along axis c (u at x = (g.x - 2) dx, y / z at the cell centre). Faces g_c = 2 and
// g_c = n_c + 2 are the domain boundary faces. Velocity buffers are SoA: [c * NS + s]. Turbulence buffers hold four
// cell-centred scalars SoA: k, omega, nu~ (SA), nu_t. Pressure and the multigrid levels use interior indexing without
// ghosts (boundary conditions are applied inline). Kinematic pressure p / rho throughout. SI units.
//
// Binding model (pw/compute.h): b0 = per-dispatch constants, u1 = scene (float4), u2..u7 = float buffers whose role
// depends on the kernel (listed per kernel), u8 = reductions (uint):
//   red[0] max |u| bits, [1] NaN flag, [2] max |r| bits (pressure residual), [3] max |b| bits (Poisson rhs),
//   [4] max nu_t bits, [5] max |div u*| bits, [8 + 12 k] surface-integral force / torque of part slot k (64-bit
//   fixed point; the ground plane is slot partCount), then the same for the IBM momentum forcing, then 4 float bits
//   per velocity sample point.
//
// Algorithms: textbook fractional-step projection (Chorin 1968; Kim & Moin 1985) on a MAC grid (Harlow & Welch
// 1965); TVD van Leer limiter (van Leer 1974) / QUICK (Leonard 1979); cell-centred geometric multigrid (Brandt 1977;
// Trottenberg, Oosterlee & Schüller 2001); direct-forcing immersed boundary (Fadlun et al. 2000, Balaras 2004);
// Reichardt (1951) law of the wall; k-omega SST (Menter, Kuntz & Langtry 2003); Spalart–Allmaras (1992);
// SST-DDES (Gritskevich, Garbaruk, Schütze & Menter 2012); WALE (Nicoud & Ducros 1999). Written from the papers for
// this project (no third-party code).

struct Consts {
    int4 a;
    int4 b;
    int4 c;
    float4 f;
    float4 g;
};
ConstantBuffer<Consts> D : register(b0);

RWStructuredBuffer<float4> scene : register(u1);
RWStructuredBuffer<float> B2 : register(u2);
RWStructuredBuffer<float> B3 : register(u3);
RWStructuredBuffer<float> B4 : register(u4);
RWStructuredBuffer<float> B5 : register(u5);
RWStructuredBuffer<float> B6 : register(u6);
RWStructuredBuffer<float> B7 : register(u7);
RWStructuredBuffer<uint> red : register(u8);

static const float KAPPA = 0.41;
static const float BETA_STAR = 0.09;

// ---------------------------------------------------------------- scene header (scene[0..11])
struct Params {
    int3 n; int NI;          // interior dims, interior cell count
    int3 S; int NS;          // storage dims, storage cell count
    int partCount, rotorCount, hasGround, turb;   // turb: 0 laminar 1 smagorinsky 2 wale 3 SA 4 SST 5 SST-DDES
    float dx, dt, nu, rho;
    float3 uFar; float convU;        // free stream (frame), convective outflow speed
    float3 center; float groundY;    // CoM and ground plane y in interior grid units (cells from the grid origin)
    float3 groundVel; float cs;      // ground velocity (frame), Smagorinsky Cs
    int faces, advection, flags, lidSide;   // faces: 3 bits per side (2 axis + hi): 0 inlet 1 outlet 2 slip 3 wall 4 open
                                            // flags: bit 0 wall functions
    float3 lidVel; float pad0;
    float4 turbFar;                  // k, omega, nu~, nu_t of the free stream
    int partBase, sampleBase, sampleCount, redSample;
};
static const int ROTOR_BASE = 12;
static const int PART_STRIDE = 8;
static const int RED_PARTS = 8;

Params loadParams() {
    Params P;
    int4 h0 = asint(scene[0]), h1 = asint(scene[1]), h2 = asint(scene[2]), h7 = asint(scene[7]), h10 = asint(scene[10]);
    float4 h3 = scene[3], h4 = scene[4], h5 = scene[5], h6 = scene[6], h8 = scene[8];
    P.n = h0.xyz; P.NI = h0.w; P.S = h1.xyz; P.NS = h1.w;
    P.partCount = h2.x; P.rotorCount = h2.y; P.hasGround = h2.z; P.turb = h2.w;
    P.dx = h3.x; P.dt = h3.y; P.nu = h3.z; P.rho = h3.w;
    P.uFar = h4.xyz; P.convU = h4.w;
    P.center = h5.xyz; P.groundY = h5.w;
    P.groundVel = h6.xyz; P.cs = h6.w;
    P.faces = h7.x; P.advection = h7.y; P.flags = h7.z; P.lidSide = h7.w;
    P.lidVel = h8.xyz; P.pad0 = h8.w;
    P.turbFar = scene[9];
    P.partBase = h10.x; P.sampleBase = h10.y; P.sampleCount = h10.z; P.redSample = h10.w;
    return P;
}

int faceType(Params P, int axis, int hi) { return (P.faces >> (3 * (2 * axis + hi))) & 7; }
bool pressureDirichlet(int t) { return t == 1 || t == 4; }

struct GPart {
    float4 rot;      // world-from-part quaternion
    float4 pos;      // part origin relative to the CoM (m); w = bound radius (m)
    float4 linVel;   // m/s relative to the domain frame
    float4 angVel;   // rad/s (world axes); w = inflation (m)
    int4 grid;       // sdf nx, ny, nz, offset
    float4 origin;   // part-local corner of the sdf grid (m); w = smallest sdf cell (m)
    int4 flags;      // x thin, y disabled
    float4 h;        // sdf cell size per part axis (m); w = band (m)
};
GPart loadPart(Params P, int k) {
    int b = P.partBase + k * PART_STRIDE;
    GPart g;
    g.rot = scene[b]; g.pos = scene[b + 1]; g.linVel = scene[b + 2]; g.angVel = scene[b + 3];
    g.grid = asint(scene[b + 4]); g.origin = scene[b + 5]; g.flags = asint(scene[b + 6]); g.h = scene[b + 7];
    return g;
}

float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }

int3 scoord(int s, Params P) { return int3(s % P.S.x, (s / P.S.x) % P.S.y, s / (P.S.x * P.S.y)); }
int sidx(int3 g, Params P) { return g.x + P.S.x * (g.y + P.S.y * g.z); }
int stride(int a, Params P) { return a == 0 ? 1 : (a == 1 ? P.S.x : P.S.x * P.S.y); }
bool interiorCell(int3 g, Params P) { return all(g >= 2) && all(g < P.n + 2); }
int3 icoord(int i, int3 n) { return int3(i % n.x, (i / n.x) % n.y, i / (n.x * n.y)); }
int iidx(int3 i, int3 n) { return i.x + n.x * (i.y + n.y * i.z); }
int3 unitv(int a) { return a == 0 ? int3(1, 0, 0) : (a == 1 ? int3(0, 1, 0) : int3(0, 0, 1)); }

#define VEL(B, c, s) B[uint(c) * uint(P.NS) + uint(s)]
#define TRB(B, c, s) B[uint(c) * uint(P.NS) + uint(s)]
#define PHI(s) B5[uint(s)]
#define SLOT(s) asint(B5[uint(P.NS) + uint(s)])

/// Grid position (interior cell units from the grid origin) of velocity component c at storage cell g.
float3 facePos(int3 g, int c) {
    float3 x = float3(g - 2) + 0.5;
    x[c] -= 0.5;
    return x;
}
float3 toMetres(Params P, float3 xg) { return (xg - P.center) * P.dx; }

/// 64-bit two's-complement fixed point (2^-24) accumulated with 32-bit atomics (as in lbm_common.slang).
static const float FIXED_SCALE = 16777216.0;
void atomicAddFixed(uint i, float x) {
    float v = round(x * FIXED_SCALE);
    if (v == 0.0 || isnan(v)) return;
    float hiF = floor(v / 4294967296.0);
    float loF = v - hiF * 4294967296.0;
    uint lo = uint(loF), hi = uint(int(hiF));
    uint old;
    InterlockedAdd(red[i], lo, old);
    uint carry = (old + lo < old) ? 1u : 0u;
    if (hi + carry != 0u) { uint o2; InterlockedAdd(red[i + 1], hi + carry, o2); }
}
void flushForce(uint b, float3 F, float3 T) {
    atomicAddFixed(b, F.x); atomicAddFixed(b + 2, F.y); atomicAddFixed(b + 4, F.z);
    atomicAddFixed(b + 6, T.x); atomicAddFixed(b + 8, T.y); atomicAddFixed(b + 10, T.z);
}
/// Per-slot force accumulation from every lane of a wave: one wave sum when all contributing lanes share the slot.
void waveFlush(uint base, int k, float3 F, float3 T) {
    int mx = WaveActiveMax(k);
    bool same = WaveActiveAllTrue(k < 0 || k == mx);
    if (same) {
        if (mx >= 0) {
            float3 sF = WaveActiveSum(F), sT = WaveActiveSum(T);
            if (WaveIsFirstLane()) flushForce(base + 12u * uint(mx), sF, sT);
        }
    } else if (k >= 0) flushForce(base + 12u * uint(k), F, T);
}
void atomicMaxPos(uint i, float v) {   // v >= 0: IEEE bits order like unsigned integers
    uint m = WaveActiveMax(asuint(max(v, 0.0)));
    if (WaveIsFirstLane()) { uint o; InterlockedMax(red[i], m, o); }
}

// ---------------------------------------------------------------- law of the wall
/// Reichardt (1951): u+ through the viscous sublayer, buffer and log layer.
float uPlus(float yp) {
    return log(1.0 + KAPPA * yp) / KAPPA + 7.8 * (1.0 - exp(-yp / 11.0) - (yp / 11.0) * exp(-yp / 3.0));
}
float dUPlus(float yp) {
    return 1.0 / (1.0 + KAPPA * yp) + 7.8 * (exp(-yp / 11.0) / 11.0 - exp(-yp / 3.0) / 11.0 + (yp / 33.0) * exp(-yp / 3.0));
}
/// Friction velocity from the tangential speed ut at wall distance y (Newton on ut = u_tau u+(y u_tau / nu)).
float frictionVelocity(float ut, float y, float nu) {
    if (ut <= 1e-9 || y <= 0.0) return 0.0;
    float t = sqrt(nu * ut / y);   // viscous-sublayer value: an upper bound, Newton descends monotonically
    for (int it = 0; it < 8; it++) {
        float yp = y * t / nu;
        float f = t * uPlus(yp) - ut;
        float df = uPlus(yp) + yp * dUPlus(yp);
        t = max(t - f / max(df, 1e-6), 0.1 * t);
    }
    return t;
}

// ---------------------------------------------------------------- geometry
float sampleGrid(GPart p, float3 l) {   // B2 = sdf data
    float3 h = p.h.xyz;
    float3 u = (l - p.origin.xyz) / h - 0.5;
    float3 n = float3(p.grid.xyz);
    if (any(u < 0.0) || any(u > n - 1.0)) {
        float3 lo = p.origin.xyz, hi = p.origin.xyz + n * h;
        float3 dd = max(max(lo - l, l - hi), 0.0);
        return length(dd) + p.h.w;
    }
    int3 i0 = min(int3(floor(u)), p.grid.xyz - 2);
    float3 fr = u - float3(i0);
    int nx = p.grid.x, ny = p.grid.y;
    int b = p.grid.w + i0.x + nx * (i0.y + ny * i0.z);
    int sy = nx, sz = nx * ny;
    float c00 = lerp(B2[b], B2[b + 1], fr.x), c10 = lerp(B2[b + sy], B2[b + sy + 1], fr.x);
    float c01 = lerp(B2[b + sz], B2[b + sz + 1], fr.x), c11 = lerp(B2[b + sy + sz], B2[b + sy + sz + 1], fr.x);
    return lerp(lerp(c00, c10, fr.y), lerp(c01, c11, fr.y), fr.z);
}

/// Signed distance (m) of the scene at pm (m relative to the CoM) and its owner (-1 none, -2 ground, k part slot).
/// Far from a part its bounding sphere gives a distance lower bound (good enough for the RANS wall distance).
float sceneSDF(Params P, float3 pm, out int part) {
    float best = 1e9; part = -1;
    for (int k = 0; k < P.partCount; k++) {
        GPart p = loadPart(P, k);
        if (p.flags.y != 0) continue;
        float3 d = pm - p.pos.xyz;
        float r = length(d);
        float s = r > p.pos.w + 2.0 * P.dx ? r - p.pos.w : sampleGrid(p, qrotInv(p.rot, d)) - p.angVel.w;
        if (s < best) { best = s; part = r > p.pos.w + 2.0 * P.dx ? -1 : k; }
    }
    if (P.hasGround != 0) {
        float sg = pm.y - (P.groundY - P.center.y) * P.dx;
        if (sg < best) { best = sg; part = -2; }
    }
    return best;
}

float3 bodyVelocity(Params P, int slot, float3 pm) {
    if (slot == -2) return P.groundVel;
    if (slot < 0) return float3(0.0, 0.0, 0.0);
    GPart p = loadPart(P, slot);
    return p.linVel.xyz + cross(p.angVel.xyz, pm - p.pos.xyz);
}

/// [B3] geo: phi (m) at [s], owner slot bits at [NS + s], for every storage cell. B2 = sdf data.
[shader("compute")][numthreads(64, 1, 1)]
void nsVoxelize(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int s = int(id.x);
    if (s >= P.NS) return;
    int3 g = scoord(s, P);
    int slot;
    float phi = sceneSDF(P, toMetres(P, float3(g - 2) + 0.5), slot);
    B3[uint(s)] = phi;
    B3[uint(P.NS) + uint(s)] = asfloat(slot);
}

/// Galilean frame change: every velocity (incl. ghosts) += D.f.xyz. [B2] U.
[shader("compute")][numthreads(64, 1, 1)]
void nsShift(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int s = int(id.x);
    if (s >= P.NS) return;
    for (int c = 0; c < 3; c++) VEL(B2, c, s) += D.f[c];
}

// ---------------------------------------------------------------- interpolation
/// Trilinear velocity (staggered) at grid position xg (interior units). B = velocity buffer selector (2 or 4).
float velComp2(Params P, int c, float3 xg) {
    float3 q = xg + 2.0 - 0.5; q[c] += 0.5;
    int3 i0 = clamp(int3(floor(q)), int3(0, 0, 0), P.S - 2);
    float3 f = clamp(q - float3(i0), 0.0, 1.0);
    int s = sidx(i0, P), sy = P.S.x, sz = P.S.x * P.S.y;
    float c00 = lerp(VEL(B2, c, s), VEL(B2, c, s + 1), f.x), c10 = lerp(VEL(B2, c, s + sy), VEL(B2, c, s + sy + 1), f.x);
    float c01 = lerp(VEL(B2, c, s + sz), VEL(B2, c, s + sz + 1), f.x), c11 = lerp(VEL(B2, c, s + sy + sz), VEL(B2, c, s + sy + sz + 1), f.x);
    return lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z);
}
float3 velocity2(Params P, float3 xg) { return float3(velComp2(P, 0, xg), velComp2(P, 1, xg), velComp2(P, 2, xg)); }

/// Gradient of phi (B5) at cell centre s, central differences (normalised; zero when degenerate).
float3 phiNormalCell(Params P, int s) {
    float3 gr;
    for (int a = 0; a < 3; a++) { int st = stride(a, P); gr[a] = PHI(s + st) - PHI(s - st); }
    float l = length(gr);
    return l > 1e-12 ? gr / l : float3(0.0, 1.0, 0.0);
}

// ---------------------------------------------------------------- momentum
float limitedFace(float U, float C, float Dn, int scheme) {
    if (scheme == 2) return 0.5 * (C + Dn);
    if (scheme == 1) return 0.75 * C + 0.375 * Dn - 0.125 * U;
    float dD = Dn - C, dU = C - U;
    if (dD * dU <= 0.0) return C;
    float r = dU / dD;
    return C + 0.5 * (r + abs(r)) / (1.0 + abs(r)) * dD;
}
/// Transported value on the face between q0 and q1 (qm upstream of q0, q2 downstream of q1) for advecting speed a.
float recon(float qm, float q0, float q1, float q2, float a, int scheme) {
    return a >= 0.0 ? limitedFace(qm, q0, q1, scheme) : limitedFace(q2, q1, q0, scheme);
}

/// Body acceleration (m/s^2) at pm (m from the CoM), component c: actuator disks (thrust reaction + swirl).
/// Rotor r: scene[ROTOR_BASE + 3r] = (centre rel. CoM (m), radius (m)), [+1] = (axis, thrust / (rho pi R^2)),
/// [+2] = (swirl coefficient sgn |Q| / (rho pi R^4 / 2), half thickness (m)).
float rotorAccel(Params P, int c, float3 pm) {
    float acc = 0.0;
    for (int r = 0; r < P.rotorCount; r++) {
        float4 ce = scene[ROTOR_BASE + 3 * r], ax = scene[ROTOR_BASE + 3 * r + 1], sw = scene[ROTOR_BASE + 3 * r + 2];
        float3 d = pm - ce.xyz;
        float al = dot(d, ax.xyz);
        float hw = 1.0 - abs(al) / sw.y;
        if (hw <= 0.0) continue;
        float3 rr = d - al * ax.xyz;
        float rad = length(rr);
        if (rad > ce.w) continue;
        float3 F = -ax.xyz * ax.w;
        if (rad > 1e-6) F += normalize(cross(ax.xyz, rr)) * (sw.x * rad);
        acc += F[c] * hw / sw.y;
    }
    return acc;
}

/// One explicit stage: out = a base + b (in + dt L(in)) on interior faces; every other face is copied from `in`.
/// [B2] in, [B3] base, [B4] out, [B6] turbulence (nu_t). D.f.x = a, D.f.y = b.
[shader("compute")][numthreads(64, 1, 1)]
void nsMomentum(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int s = int(id.x);
    if (s >= P.NS) return;
    int3 g = scoord(s, P);
    bool inner = interiorCell(g, P);
    float A = D.f.x, Bc = D.f.y;
    float dx = P.dx, idx = 1.0 / dx, idx2 = idx * idx;
    for (int c = 0; c < 3; c++) {
        float q = VEL(B2, c, s);
        float outv = q;
        if (inner && g[c] >= 3) {
            int sc = stride(c, P);
            float rhs = 0.0;
            for (int d = 0; d < 3; d++) {
                int sd = stride(d, P);
                float aHi, aLo, nHi, nLo;
                if (d == c) {
                    aHi = 0.5 * (q + VEL(B2, c, s + sd));
                    aLo = 0.5 * (VEL(B2, c, s - sd) + q);
                    nHi = TRB(B6, 3, s); nLo = TRB(B6, 3, s - sc);
                } else {
                    aHi = 0.5 * (VEL(B2, d, s + sd) + VEL(B2, d, s + sd - sc));
                    aLo = 0.5 * (VEL(B2, d, s) + VEL(B2, d, s - sc));
                    nHi = 0.25 * (TRB(B6, 3, s) + TRB(B6, 3, s - sc) + TRB(B6, 3, s + sd) + TRB(B6, 3, s + sd - sc));
                    nLo = 0.25 * (TRB(B6, 3, s) + TRB(B6, 3, s - sc) + TRB(B6, 3, s - sd) + TRB(B6, 3, s - sd - sc));
                }
                float qm2 = VEL(B2, c, s - 2 * sd), qm1 = VEL(B2, c, s - sd), qp1 = VEL(B2, c, s + sd), qp2 = VEL(B2, c, s + 2 * sd);
                float fHi = aHi * recon(qm1, q, qp1, qp2, aHi, P.advection);
                float fLo = aLo * recon(qm2, qm1, q, qp1, aLo, P.advection);
                rhs -= (fHi - fLo) * idx;
                rhs += ((P.nu + nHi) * (qp1 - q) - (P.nu + nLo) * (q - qm1)) * idx2;
            }
            if (P.rotorCount > 0) rhs += rotorAccel(P, c, toMetres(P, facePos(g, c)));
            outv = A * VEL(B3, c, s) + Bc * (q + P.dt * rhs);
        }
        VEL(B4, c, s) = outv;
    }
}

// ---------------------------------------------------------------- immersed boundary
/// Direct forcing: faces inside a body take the body velocity; faces in the first fluid layer (0 <= phi < dx) are
/// reconstructed along the wall normal from the velocity at a probe one cell further out (normal component linear,
/// tangential component by the law of the wall, which is linear in the viscous sublayer).
/// The momentum the forcing removes from the fluid is the force on the body (Uhlmann 2005): accumulated per slot as
/// a cross-check of the surface integral (D.f.x = stage weight rho dx^3 / dt).
/// [B2] in (predicted), [B3] out, [B5] geo. Every storage face is written.
[shader("compute")][numthreads(64, 1, 1)]
void nsIBM(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int s = int(id.x);
    float3 aF = float3(0.0, 0.0, 0.0), aT = float3(0.0, 0.0, 0.0);
    int curK = -1;
    if (s < P.NS) {
    int3 g = scoord(s, P);
    bool inner = interiorCell(g, P);
    float dx = P.dx;
    bool wallFn = (P.flags & 1) != 0;
    for (int c = 0; c < 3; c++) {
        float v = VEL(B2, c, s);
        if (inner && g[c] >= 3) {
            int sc = stride(c, P);
            float pa = PHI(s), pb = PHI(s - sc);
            float ph = 0.5 * (pa + pb);
            if (ph < dx) {
                int slot = pa < pb ? SLOT(s) : SLOT(s - sc);
                float3 xf = facePos(g, c);
                float3 ub = bodyVelocity(P, slot, toMetres(P, xf));
                if (ph <= 0.0 || slot == -1) v = ph <= 0.0 ? ub[c] : v;
                else {
                    float3 gr;
                    for (int a = 0; a < 3; a++) {
                        int sa = stride(a, P);
                        gr[a] = a == c ? 2.0 * (pa - pb) : 0.5 * ((PHI(s + sa) - PHI(s - sa)) + (PHI(s - sc + sa) - PHI(s - sc - sa)));
                    }
                    float gl = length(gr);
                    float3 nrm = gl > 1e-12 ? gr / gl : float3(0.0, 1.0, 0.0);
                    float dp = ph + dx;
                    float3 rel = velocity2(P, xf + nrm) - ub;
                    float un = dot(rel, nrm);
                    float3 ut = rel - un * nrm;
                    float utm = length(ut);
                    float fr = ph / dp;
                    float utf = utm * fr;
                    if (wallFn && utm > 1e-7) {
                        float tau = frictionVelocity(utm, dp, P.nu);
                        utf = min(tau * uPlus(ph * tau / P.nu), utm);
                    }
                    float3 vf = ub + nrm * (un * fr) + (utm > 1e-9 ? ut * (utf / utm) : float3(0.0, 0.0, 0.0));
                    v = vf[c];
                }
                if (slot != -1) {
                    int k = slot == -2 ? P.partCount : slot;
                    float df = -(v - VEL(B2, c, s)) * D.f.x;   // force on the body = - momentum added to the fluid
                    if (curK < 0 || curK == k) {
                        curK = k;
                        float3 dF = float3(0.0, 0.0, 0.0); dF[c] = df;
                        aF += dF; aT += cross(toMetres(P, xf), dF);
                    }
                }
            }
        }
        VEL(B3, c, s) = v;
    }
    }
    waveFlush(uint(RED_PARTS + 12 * (P.partCount + 1)), curK, aF, aT);
}

// ---------------------------------------------------------------- boundary conditions
/// Ghost layers (and boundary-normal faces) of one axis. [B2] U, [B3] turbulence, [B5] geo. D.a.x = axis,
/// D.a.y = flags: bit 0 convective update of outflow boundary faces, bit 1 velocity, bit 2 turbulence.
/// Threads: 2 sides x 2 layers x S_b x S_c.
[shader("compute")][numthreads(64, 1, 1)]
void nsBC(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int ax = D.a.x, flags = D.a.y;
    int bA = (ax + 1) % 3, cA = (ax + 2) % 3;
    int Sb = P.S[bA], Sc = P.S[cA];
    int t = int(id.x);
    if (t >= 4 * Sb * Sc) return;
    int ib = t % Sb, ic = (t / Sb) % Sc, layer = (t / (Sb * Sc)) % 2, hi = t / (2 * Sb * Sc);
    int n = P.n[ax];
    int gG = hi != 0 ? n + 2 + layer : 1 - layer;   // ghost cell
    int gM = hi != 0 ? n + 1 - layer : 2 + layer;   // its interior mirror
    int3 g; g[ax] = gG; g[bA] = ib; g[cA] = ic;
    int3 m = g; m[ax] = gM;
    int sG = sidx(g, P), sM = sidx(m, P);
    int type = faceType(P, ax, hi);
    int side = 2 * ax + hi;
    float3 wallV = side == P.lidSide ? P.lidVel : float3(0.0, 0.0, 0.0);
    if ((flags & 2) != 0) {
        for (int c = 0; c < 3; c++) {
            if (c == ax) continue;
            float vm = VEL(B2, c, sM), vg;
            if (type == 0) vg = 2.0 * P.uFar[c] - vm;
            else if (type == 3) vg = 2.0 * wallV[c] - vm;
            else vg = vm;
            VEL(B2, c, sG) = vg;
        }
        if (layer == 0) {
            // normal component: boundary face fb, its inward neighbour fi, ghost faces
            int st = stride(ax, P);
            int3 fbG = g; fbG[ax] = hi != 0 ? n + 2 : 2;
            int sb = sidx(fbG, P), si = hi != 0 ? sb - st : sb + st;
            float ubd = VEL(B2, ax, sb);
            if (type == 0 || type == 2) ubd = P.uFar[ax];
            else if (type == 3) ubd = wallV[ax];
            else if ((flags & 1) != 0) {
                float uin = VEL(B2, ax, si);
                ubd = type == 1 ? ubd - P.dt * P.convU * (ubd - uin) / P.dx : uin;
            }
            // boundary faces inside a body (e.g. the ground crossing an inlet) take the body velocity, or the solver
            // would see a mass source there
            float pf = 0.5 * (PHI(sb) + PHI(hi != 0 ? sb : sb - st));
            if (pf < 0.0) {
                int slot = SLOT(hi != 0 ? sb - st : sb);
                ubd = bodyVelocity(P, slot, toMetres(P, facePos(fbG, ax)))[ax];
            }
            VEL(B2, ax, sb) = ubd;
            if (hi != 0) VEL(B2, ax, sb + st) = ubd;
            else { VEL(B2, ax, sb - st) = ubd; VEL(B2, ax, sb - 2 * st) = ubd; }
        }
    }
    if ((flags & 4) != 0) {
        for (int c = 0; c < 4; c++) {
            float vm = TRB(B3, c, sM), vg = vm;
            if (type == 0) vg = P.turbFar[c];
            else if (type == 3 && c != 1) vg = 0.0;
            TRB(B3, c, sG) = vg;
        }
    }
}

// ---------------------------------------------------------------- pressure
/// rhs = div(u*) / dt on interior cells. [B2] U, [B3] rhs (interior indexing). D.f.x = 1 / dt.
[shader("compute")][numthreads(64, 1, 1)]
void nsDivergence(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(id.x);
    float dv = 0.0;
    if (i < P.NI) {
        int s = sidx(icoord(i, P.n) + 2, P);
        for (int c = 0; c < 3; c++) dv += VEL(B2, c, s + stride(c, P)) - VEL(B2, c, s);
        dv /= P.dx;
        B3[uint(i)] = dv * D.f.x;
    }
    atomicMaxPos(5, abs(dv));
}

/// u -= dt grad p on interior faces and on outflow (p = 0) boundary faces. [B2] U, [B3] p. D.f.x = dt.
/// Also: max |u| and the NaN flag.
[shader("compute")][numthreads(64, 1, 1)]
void nsProject(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(id.x);
    float sp = 0.0; bool bad = false;
    if (i < P.NI) {
        int3 ic = icoord(i, P.n);
        int s = sidx(ic + 2, P);
        float dt = D.f.x, idx = 1.0 / P.dx;
        float p0 = B3[uint(i)];
        float3 u;
        for (int c = 0; c < 3; c++) {
            int st = stride(c, P);
            float grad = 0.0;
            if (ic[c] > 0) grad = (p0 - B3[uint(iidx(ic - unitv(c), P.n))]) * idx;
            else if (pressureDirichlet(faceType(P, c, 0))) grad = 2.0 * p0 * idx;
            float v = VEL(B2, c, s) - dt * grad;
            VEL(B2, c, s) = v;
            u[c] = v;
            if (ic[c] == P.n[c] - 1 && pressureDirichlet(faceType(P, c, 1))) VEL(B2, c, s + st) -= dt * (-2.0 * p0 * idx);
        }
        sp = length(u);
        bad = isnan(sp) || isinf(sp);
    }
    atomicMaxPos(0, bad ? 0.0 : sp);
    bool anyBad = WaveActiveAnyTrue(bad);
    if (anyBad && WaveIsFirstLane()) { uint o; InterlockedOr(red[1], 1u, o); }
}

// ---------------------------------------------------------------- multigrid (cell-centred, inline boundary conditions)
// Level constants: dims, 1/h^2 per axis, Dirichlet mask (bit 2a: low side of axis a, bit 2a+1: high side).
float lapNeighbours(RWStructuredBuffer<float> X, int3 c, int3 dim, float3 ih2, int mask, out float diag) {
    float sum = 0.0; diag = 0.0;
    int i = iidx(c, dim);
    for (int a = 0; a < 3; a++) {
        int st = a == 0 ? 1 : (a == 1 ? dim.x : dim.x * dim.y);
        if (c[a] > 0) { sum += X[uint(i - st)] * ih2[a]; diag += ih2[a]; }
        else if ((mask & (1 << (2 * a))) != 0) diag += 2.0 * ih2[a];
        if (c[a] < dim[a] - 1) { sum += X[uint(i + st)] * ih2[a]; diag += ih2[a]; }
        else if ((mask & (1 << (2 * a + 1))) != 0) diag += 2.0 * ih2[a];
    }
    return sum;
}

/// Red-black Gauss–Seidel half sweep. [B2] x, [B3] b. D.a.xyz = dims, D.b.x = colour, D.b.y = mask, D.f.xyz = 1/h^2.
[shader("compute")][numthreads(64, 1, 1)]
void mgSmooth(uint3 id : SV_DispatchThreadID) {
    int3 dim = D.a.xyz;
    int i = int(id.x);
    if (i >= dim.x * dim.y * dim.z) return;
    int3 c = icoord(i, dim);
    if (((c.x + c.y + c.z) & 1) != D.b.x) return;
    float diag;
    float sum = lapNeighbours(B2, c, dim, D.f.xyz, D.b.y, diag);
    if (diag > 0.0) B2[uint(i)] = (sum - B3[uint(i)]) / diag;
}

float residualAt(RWStructuredBuffer<float> X, RWStructuredBuffer<float> Bv, int3 c, int3 dim, float3 ih2, int mask) {
    float diag;
    float sum = lapNeighbours(X, c, dim, ih2, mask, diag);
    int i = iidx(c, dim);
    return Bv[uint(i)] - (sum - diag * X[uint(i)]);
}

/// Coarse rhs = average of the fine residuals of the children; coarse x = 0.
/// [B2] x fine, [B3] b fine, [B4] x coarse, [B5] b coarse. D.a = fine dims, D.b = coarse dims, D.c.xyz = ratio,
/// D.c.w = mask, D.f.xyz = fine 1/h^2.
[shader("compute")][numthreads(64, 1, 1)]
void mgRestrict(uint3 id : SV_DispatchThreadID) {
    int3 dimF = D.a.xyz, dimC = D.b.xyz, r = D.c.xyz;
    int i = int(id.x);
    if (i >= dimC.x * dimC.y * dimC.z) return;
    int3 cc = icoord(i, dimC);
    float sum = 0.0; int cnt = 0;
    for (int dz = 0; dz < r.z; dz++)
        for (int dy = 0; dy < r.y; dy++)
            for (int dxx = 0; dxx < r.x; dxx++) {
                int3 f = cc * r + int3(dxx, dy, dz);
                sum += residualAt(B2, B3, f, dimF, D.f.xyz, D.c.w);
                cnt += 1;
            }
    B5[uint(i)] = sum / float(cnt);
    B4[uint(i)] = 0.0;
}

float coarseValue(int3 J, int3 dimC, int mask) {   // B4 = coarse x, homogeneous boundary conditions
    float sgn = 1.0;
    for (int a = 0; a < 3; a++) {
        if (J[a] < 0) { J[a] = 0; if ((mask & (1 << (2 * a))) != 0) sgn = -sgn; }
        else if (J[a] >= dimC[a]) { J[a] = dimC[a] - 1; if ((mask & (1 << (2 * a + 1))) != 0) sgn = -sgn; }
    }
    return sgn * B4[uint(iidx(J, dimC))];
}

/// x fine += trilinear(x coarse). [B2] x fine, [B4] x coarse. D.a = fine dims, D.b = coarse dims, D.c.xyz = ratio,
/// D.c.w = mask.
[shader("compute")][numthreads(64, 1, 1)]
void mgProlong(uint3 id : SV_DispatchThreadID) {
    int3 dimF = D.a.xyz, dimC = D.b.xyz, r = D.c.xyz;
    int i = int(id.x);
    if (i >= dimF.x * dimF.y * dimF.z) return;
    int3 f = icoord(i, dimF);
    int3 I = f / r;
    int3 o;
    for (int a = 0; a < 3; a++) o[a] = r[a] == 2 ? ((f[a] & 1) != 0 ? 1 : -1) : 0;
    float acc = 0.0;
    for (int k = 0; k < 8; k++) {
        int3 bit = int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        if (any(bit * int3(o == 0) != 0)) continue;   // no vector && (HLSL 2021 rejects it)
        float w = 1.0;
        for (int a = 0; a < 3; a++) if (o[a] != 0) w *= bit[a] != 0 ? 0.25 : 0.75;
        acc += w * coarseValue(I + bit * o, dimC, D.c.w);
    }
    B2[uint(i)] += acc;
}

groupshared float gsum[256];
/// Coarsest level: D.b.x red-black sweeps by one threadgroup; the mean is removed for pure-Neumann problems.
/// [B2] x, [B3] b. D.a = dims, D.b.x = iterations, D.b.y = mask, D.b.z = 1 when pure Neumann, D.f.xyz = 1/h^2.
[shader("compute")][numthreads(256, 1, 1)]
void mgCoarse(uint3 tid : SV_GroupThreadID) {
    int3 dim = D.a.xyz;
    int N = dim.x * dim.y * dim.z;
    int t = int(tid.x);
    for (int it = 0; it < D.b.x; it++)
        for (int col = 0; col < 2; col++) {
            for (int i = t; i < N; i += 256) {
                int3 c = icoord(i, dim);
                if (((c.x + c.y + c.z) & 1) != col) continue;
                float diag;
                float sum = lapNeighbours(B2, c, dim, D.f.xyz, D.b.y, diag);
                if (diag > 0.0) B2[uint(i)] = (sum - B3[uint(i)]) / diag;
            }
            AllMemoryBarrierWithGroupSync();
        }
    if (D.b.z != 0) {
        float s = 0.0;
        for (int i = t; i < N; i += 256) s += B2[uint(i)];
        gsum[t] = s;
        GroupMemoryBarrierWithGroupSync();
        for (int w = 128; w > 0; w >>= 1) {
            if (t < w) gsum[t] += gsum[t + w];
            GroupMemoryBarrierWithGroupSync();
        }
        float mean = gsum[0] / float(N);
        for (int i = t; i < N; i += 256) B2[uint(i)] -= mean;
    }
}

/// max |r| and max |b| of level 0 into red[2], red[3]. [B2] x, [B3] b. D.a = dims, D.b.y = mask, D.f.xyz = 1/h^2.
[shader("compute")][numthreads(64, 1, 1)]
void mgResidual(uint3 id : SV_DispatchThreadID) {
    int3 dim = D.a.xyz;
    int i = int(id.x);
    float r = 0.0, b = 0.0;
    if (i < dim.x * dim.y * dim.z) {
        r = abs(residualAt(B2, B3, icoord(i, dim), dim, D.f.xyz, D.b.y));
        b = abs(B3[uint(i)]);
    }
    atomicMaxPos(2, r);
    atomicMaxPos(3, b);
}

// ---------------------------------------------------------------- turbulence
/// Cell-centred velocity gradient G[a][b] = du_a / dx_b at storage cell s (B2 = U).
float3x3 velGrad(Params P, int s) {
    float3x3 G;
    float idx = 1.0 / P.dx;
    for (int a = 0; a < 3; a++) {
        int sa = stride(a, P);
        for (int b = 0; b < 3; b++) {
            if (a == b) { G[a][b] = (VEL(B2, a, s + sa) - VEL(B2, a, s)) * idx; continue; }
            int sb = stride(b, P);
            float up = 0.5 * (VEL(B2, a, s + sb) + VEL(B2, a, s + sb + sa));
            float dn = 0.5 * (VEL(B2, a, s - sb) + VEL(B2, a, s - sb + sa));
            G[a][b] = (up - dn) * 0.5 * idx;
        }
    }
    return G;
}

/// Upwind advection (non-conservative correction: u.grad q) + diffusion div(Gamma grad q) of scalar comp q (B3 = T).
/// gam = Gamma at this cell, gamNb(cell) evaluated as nu + sigma nu_t(neighbour).
float scalarTransport(Params P, int s, int q, float sigma, bool saDiffusion) {
    float idx = 1.0 / P.dx, idx2 = idx * idx;
    float v = TRB(B3, q, s);
    float adv = 0.0, dif = 0.0;
    float g0 = saDiffusion ? P.nu + v : P.nu + sigma * TRB(B3, 3, s);
    for (int d = 0; d < 3; d++) {
        int sd = stride(d, P);
        float aLo = VEL(B2, d, s), aHi = VEL(B2, d, s + sd);
        float vm = TRB(B3, q, s - sd), vp = TRB(B3, q, s + sd);
        float fHi = aHi >= 0.0 ? aHi * v : aHi * vp;
        float fLo = aLo >= 0.0 ? aLo * vm : aLo * v;
        adv += (fHi - fLo - v * (aHi - aLo)) * idx;
        float gm = saDiffusion ? P.nu + vm : P.nu + sigma * TRB(B3, 3, s - sd);
        float gp = saDiffusion ? P.nu + vp : P.nu + sigma * TRB(B3, 3, s + sd);
        dif += (0.5 * (g0 + gp) * (vp - v) - 0.5 * (g0 + gm) * (v - vm)) * idx2;
    }
    return dif - adv;
}

float3 scalarGrad(Params P, int s, int q) {
    float3 gr;
    for (int a = 0; a < 3; a++) { int st = stride(a, P); gr[a] = (TRB(B3, q, s + st) - TRB(B3, q, s - st)) * 0.5 / P.dx; }
    return gr;
}

/// Wall quantities at cell centre s (phi >= 0): friction velocity from the tangential velocity at the probe
/// (wall distance phi + dx).
float cellFrictionVelocity(Params P, int s, int3 g, float phi) {
    int slot = SLOT(s);
    float3 nrm = phiNormalCell(P, s);
    float3 xc = float3(g - 2) + 0.5;
    float3 xw = xc - nrm * (phi / P.dx);
    float3 ub = bodyVelocity(P, slot, toMetres(P, xw));
    float3 rel = velocity2(P, xc + nrm) - ub;
    float3 ut = rel - dot(rel, nrm) * nrm;
    return frictionVelocity(length(ut), phi + P.dx, P.nu);
}

/// Eddy viscosity and turbulence transport, once per NS step. [B2] U, [B3] T in, [B4] T out, [B5] geo, red[4].
[shader("compute")][numthreads(64, 1, 1)]
void nsTurbulence(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(id.x);
    float nutOut = 0.0;
    if (i < P.NI) {
        int3 g = icoord(i, P.n) + 2;
        int s = sidx(g, P);
        float dx = P.dx, nu = P.nu, dt = P.dt;
        float phi = PHI(s);
        float dw = max(phi, 0.05 * dx);
        float3x3 G = velGrad(P, s);
        float3x3 Sm = 0.5 * (G + transpose(G)), Wm = 0.5 * (G - transpose(G));
        float S2 = 0.0, W2 = 0.0;
        for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) { S2 += 2.0 * Sm[a][b] * Sm[a][b]; W2 += 2.0 * Wm[a][b] * Wm[a][b]; }
        float Smag = sqrt(S2), Om = sqrt(W2);
        float4 T = float4(TRB(B3, 0, s), TRB(B3, 1, s), TRB(B3, 2, s), TRB(B3, 3, s));
        float4 To = T;
        bool wallFn = (P.flags & 1) != 0;
        if (P.turb == 0) To.w = 0.0;
        else if (P.turb == 1) {
            float l = min(P.cs * dx, KAPPA * dw);
            To.w = phi > 0.0 ? l * l * Smag : 0.0;
        } else if (P.turb == 2) {
            float3x3 G2 = mul(G, G);
            float tr = (G2[0][0] + G2[1][1] + G2[2][2]) / 3.0;
            float3x3 Sd = 0.5 * (G2 + transpose(G2));
            Sd[0][0] -= tr; Sd[1][1] -= tr; Sd[2][2] -= tr;
            float sdsd = 0.0, ss = 0.0;
            for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) { sdsd += Sd[a][b] * Sd[a][b]; ss += Sm[a][b] * Sm[a][b]; }
            float l = 0.5 * dx;   // Cw = 0.5
            float den = pow(ss, 2.5) + pow(sdsd, 1.25);
            To.w = phi > 0.0 && den > 1e-30 ? l * l * pow(sdsd, 1.5) / den : 0.0;
        } else if (phi < 0.0) {
            // inside a body: wall values (k zero-gradient through the probe, omega large, nu~ = 0)
            float3 nrm = phiNormalCell(P, s);
            float3 xp = float3(g - 2) + 0.5 + nrm * (1.0 - phi / dx);
            int3 gp = clamp(int3(floor(xp)) + 2, int3(2, 2, 2), P.n + 1);
            float kp = TRB(B3, 0, sidx(gp, P));
            float yh = 0.5 * dx;
            To = float4(phi > -2.0 * dx ? kp : 0.0, 6.0 * nu / (0.075 * yh * yh), 0.0, 0.0);
        } else if (P.turb == 3) {
            // Spalart–Allmaras (noft2)
            const float cb1 = 0.1355, cb2 = 0.622, sig = 2.0 / 3.0, cv1 = 7.1, cw2 = 0.3, cw3 = 2.0;
            const float cw1 = cb1 / (KAPPA * KAPPA) + (1.0 + cb2) / sig;
            float nt = max(T.z, 0.0);
            float chi = nt / nu, chi3 = chi * chi * chi;
            float fv1 = chi3 / (chi3 + cv1 * cv1 * cv1);
            float fv2 = 1.0 - chi / (1.0 + chi * fv1);
            float kd2 = KAPPA * KAPPA * dw * dw;
            float St = max(Om + nt * fv2 / kd2, 0.3 * Om);
            float r = St > 1e-12 ? min(nt / (St * kd2), 10.0) : 10.0;
            float gg = r + cw2 * (pow(r, 6.0) - r);
            float fw = gg * pow((1.0 + pow(cw3, 6.0)) / (pow(gg, 6.0) + pow(cw3, 6.0)), 1.0 / 6.0);
            float3 gn = scalarGrad(P, s, 2);
            float tr = scalarTransport(P, s, 2, 1.0, true);
            // scalarTransport returns dif - adv with Gamma = nu + nu~; SA diffusion is (1 / sigma) of it (+ cb2 term)
            float advOnly = 0.0;
            {
                float idx = 1.0 / dx;
                for (int d = 0; d < 3; d++) {
                    int sd = stride(d, P);
                    float aLo = VEL(B2, d, s), aHi = VEL(B2, d, s + sd);
                    float vm = TRB(B3, 2, s - sd), vp = TRB(B3, 2, s + sd);
                    float fHi = aHi >= 0.0 ? aHi * nt : aHi * vp;
                    float fLo = aLo >= 0.0 ? aLo * vm : aLo * nt;
                    advOnly += (fHi - fLo - nt * (aHi - aLo)) * idx;
                }
            }
            float dif = tr + advOnly;
            float rhs = -advOnly + (dif + cb2 * dot(gn, gn)) / sig + cb1 * St * nt;
            float ntn = (nt + dt * rhs) / (1.0 + dt * cw1 * fw * nt / (dw * dw));
            if (phi < dx && wallFn) {
                float ut = cellFrictionVelocity(P, s, g, phi);
                float yp = dw * ut / nu;
                float w = clamp((yp - 5.0) / 25.0, 0.0, 1.0);
                ntn = lerp(ntn, KAPPA * ut * dw, w);
            }
            ntn = clamp(ntn, 0.0, 1e5 * nu);
            float c3 = pow(ntn / nu, 3.0);
            To = float4(0.0, 0.0, ntn, ntn * c3 / (c3 + cv1 * cv1 * cv1));
        } else {
            // k-omega SST (Menter 2003) / SST-DDES (Gritskevich 2012)
            const float a1 = 0.31, sw2 = 0.856;
            float k = max(T.x, 1e-12), w = max(T.y, 1e-8);
            float3 gk = scalarGrad(P, s, 0), gw = scalarGrad(P, s, 1);
            float cdkw = max(2.0 * sw2 / w * dot(gk, gw), 1e-20);
            float sk = sqrt(k);
            float arg1 = min(max(sk / (BETA_STAR * w * dw), 500.0 * nu / (dw * dw * w)), 4.0 * sw2 * k / (cdkw * dw * dw));
            float F1 = tanh(pow(arg1, 4.0));
            float arg2 = max(2.0 * sk / (BETA_STAR * w * dw), 500.0 * nu / (dw * dw * w));
            float F2 = tanh(arg2 * arg2);
            float sigk = lerp(1.0, 0.85, F1), sigw = lerp(0.856, 0.5, F1);
            float beta = lerp(0.0828, 0.075, F1), alpha = lerp(0.44, 5.0 / 9.0, F1);
            float nt = T.w;
            float Pk = min(nt * S2, 10.0 * BETA_STAR * k * w);
            float dk = BETA_STAR * w;   // k destruction rate (per s)
            if (P.turb == 5) {
                float lr = sk / (BETA_STAR * w);
                float lles = lerp(0.61, 0.78, F1) * dx;
                float rd = (nt + nu) / (KAPPA * KAPPA * dw * dw * sqrt(max(0.5 * (S2 + W2), 1e-20)));
                float fd = 1.0 - tanh(pow(20.0 * rd, 3.0));
                float l = lr - fd * max(0.0, lr - lles);
                dk = sk / max(l, 1e-9);
            }
            float kt = scalarTransport(P, s, 0, sigk, false), wt = scalarTransport(P, s, 1, sigw, false);
            float kn = (k + dt * (kt + Pk)) / (1.0 + dt * dk);
            float cross = 2.0 * (1.0 - F1) * sw2 / w * dot(gk, gw);
            float wn = (w + dt * (wt + alpha * S2 + max(cross, 0.0))) / (1.0 + dt * (beta * w - min(cross, 0.0) / w));
            if (phi < dx) {
                // automatic wall treatment: omega blends sublayer and log-layer values, k its log-layer equilibrium
                float ut = cellFrictionVelocity(P, s, g, phi);
                float wv = 6.0 * nu / (0.075 * dw * dw), wl = ut / (sqrt(BETA_STAR) * KAPPA * dw);
                wn = sqrt(wv * wv + wl * wl);
                if (wallFn) {
                    float yp = dw * ut / nu;
                    kn = lerp(kn, ut * ut / sqrt(BETA_STAR), clamp((yp - 5.0) / 25.0, 0.0, 1.0));
                }
            }
            kn = clamp(kn, 1e-10 * P.turbFar.x, 1e6);
            wn = clamp(wn, 1e-3 * P.turbFar.y, 1e12);
            float sk2 = sqrt(kn);
            float arg2n = max(2.0 * sk2 / (BETA_STAR * wn * dw), 500.0 * nu / (dw * dw * wn));
            float ntn = a1 * kn / max(a1 * wn, Smag * tanh(arg2n * arg2n));
            To = float4(kn, wn, 0.0, min(ntn, 1e5 * nu));
        }
        if (phi < 0.0 && P.turb <= 2) To.w = 0.0;
        if (isnan(To.x) || isnan(To.y) || isnan(To.z) || isnan(To.w)) To = P.turbFar;
        for (int c = 0; c < 4; c++) TRB(B4, c, s) = To[c];
        nutOut = To.w;
    }
    atomicMaxPos(4, nutOut);
}

// ---------------------------------------------------------------- forces
float pressureAt(Params P, float3 xg) {   // B3 = p (interior indexing), trilinear at cell centres
    float3 q = xg - 0.5;
    int3 i0 = clamp(int3(floor(q)), int3(0, 0, 0), max(P.n - 2, int3(0, 0, 0)));
    float3 f = clamp(q - float3(i0), 0.0, 1.0);
    int3 i1 = min(i0 + 1, P.n - 1);
    float c00 = lerp(B3[iidx(i0, P.n)], B3[iidx(int3(i1.x, i0.y, i0.z), P.n)], f.x);
    float c10 = lerp(B3[iidx(int3(i0.x, i1.y, i0.z), P.n)], B3[iidx(int3(i1.x, i1.y, i0.z), P.n)], f.x);
    float c01 = lerp(B3[iidx(int3(i0.x, i0.y, i1.z), P.n)], B3[iidx(int3(i1.x, i0.y, i1.z), P.n)], f.x);
    float c11 = lerp(B3[iidx(int3(i0.x, i1.y, i1.z), P.n)], B3[iidx(i1, P.n)], f.x);
    return lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z);
}

/// Surface traction integral per part: F = sum over the signed-distance band of (-p n + tau_w t) delta_eps(phi) dV,
/// p and the wall shear from a probe 1.5 cells outside the surface point (dp/dn ~ 0 across the boundary layer; the
/// shear by the law of the wall). Torque about the CoM. Accumulated per NS step. [B2] U, [B3] p, [B5] geo.
[shader("compute")][numthreads(64, 1, 1)]
void nsForces(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(id.x);
    int k = -1;
    float3 F = float3(0.0, 0.0, 0.0), T = float3(0.0, 0.0, 0.0);
    int3 g = icoord(min(i, P.NI - 1), P.n) + 2;
    int s = sidx(g, P);
    float dx = P.dx, eps = 1.5 * dx;
    float phi = PHI(s);
    int slot = SLOT(s);
    if (i < P.NI && abs(phi) < eps && slot != -1) {
    k = slot == -2 ? P.partCount : slot;
    float3 n = phiNormalCell(P, s);
    float del = (1.0 + cos(3.14159265 * phi / eps)) / (2.0 * eps);
    float3 xc = float3(g - 2) + 0.5;
    float3 xs = xc - n * (phi / dx);
    const float h1 = 1.5, h2 = 2.5;
    float3 pm = toMetres(P, xs);
    float3 ub = bodyVelocity(P, slot, pm);
    float3 r1 = velocity2(P, xs + n * h1) - ub, r2 = velocity2(P, xs + n * h2) - ub;
    float3 ut = r1 - dot(r1, n) * n;
    float utm = length(ut);
    float tau = 0.0;
    if (utm > 1e-9) {
        float3 tdir = ut / utm;
        float u2 = dot(r2, tdir);
        // laminar: quadratic profile through the wall (u = 0) and both probes; turbulent: law of the wall at probe 1
        float grad = (utm * h2 * h2 - u2 * h1 * h1) / (h1 * h2 * (h2 - h1) * dx);
        float tl = P.nu * max(grad, utm / (h2 * dx));
        float uf = frictionVelocity(utm, h1 * dx, P.nu);
        float yp = h1 * dx * uf / P.nu;
        float wt = (P.flags & 1) != 0 ? clamp((yp - 5.0) / 25.0, 0.0, 1.0) : 0.0;
        tau = lerp(tl, uf * uf, wt);
    }
    float p1 = pressureAt(P, xs + n * h1), p2 = pressureAt(P, xs + n * h2);
    float pw = p1 + (p1 - p2) * (h1 / (h2 - h1));
    float3 tr = P.rho * (-pw * n + (utm > 1e-9 ? tau * ut / utm : float3(0.0, 0.0, 0.0)));
    float w = del * dx * dx * dx;
    F = tr * w; T = cross(pm, F);
    }
    waveFlush(uint(RED_PARTS), k, F, T);
}

/// Velocity at the sample points (grid units in scene[sampleBase + i]) into red[redSample + 4 i]. [B2] U.
[shader("compute")][numthreads(64, 1, 1)]
void nsSample(uint3 id : SV_DispatchThreadID) {
    Params P = loadParams();
    int i = int(id.x);
    if (i >= P.sampleCount) return;
    float3 xg = scene[P.sampleBase + i].xyz;
    float3 u = velocity2(P, xg);
    uint o = uint(P.redSample + 4 * i);
    red[o] = asuint(u.x); red[o + 1] = asuint(u.y); red[o + 2] = asuint(u.z); red[o + 3] = asuint(1.0);
}

/// [B2] destination, D.a.x = count, D.f.x = value.
[shader("compute")][numthreads(64, 1, 1)]
void nsFill(uint3 id : SV_DispatchThreadID) {
    if (int(id.x) < D.a.x) B2[id.x] = D.f.x;
}

/// [red] zero the first D.a.x words.
[shader("compute")][numthreads(64, 1, 1)]
void nsClear(uint3 id : SV_DispatchThreadID) {
    if (int(id.x) < D.a.x) red[id.x] = 0u;
}
