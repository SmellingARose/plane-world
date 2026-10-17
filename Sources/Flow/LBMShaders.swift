// Metal source for the lattice-Boltzmann solver, compiled at runtime (one library per velocity set).
// Layout: populations are SoA float, f[i*N + cell]; cell = x + nx*(y + ny*z). Two-kernel scheme per LBM step:
//   collide (in place: f -> f*, writes macroscopic ρ,u)  then  stream (pull f* -> f_next, walls, momentum exchange).
// All lattice quantities are in lattice units (dx = dt = 1, ρ0 = 1, c_s² = 1/3).
import Foundation

enum LBMVelocitySet {
    /// (c, w) for D3Q19 / D3Q27, rest velocity first, then opposite pairs adjacent (i, i+1).
    static func table(q: Int) -> [(SIMD3<Int32>, Float)] {
        var out: [(SIMD3<Int32>, Float)] = [(.zero, q == 19 ? 1.0 / 3 : 8.0 / 27)]
        func add(_ c: SIMD3<Int32>, _ w: Float) { out.append((c, w)); out.append((SIMD3<Int32>(0, 0, 0) &- c, w)) }
        let face: Float = q == 19 ? 1.0 / 18 : 2.0 / 27, edge: Float = q == 19 ? 1.0 / 36 : 1.0 / 54
        add(SIMD3(1, 0, 0), face); add(SIMD3(0, 1, 0), face); add(SIMD3(0, 0, 1), face)
        add(SIMD3(1, 1, 0), edge); add(SIMD3(1, -1, 0), edge); add(SIMD3(1, 0, 1), edge)
        add(SIMD3(1, 0, -1), edge); add(SIMD3(0, 1, 1), edge); add(SIMD3(0, 1, -1), edge)
        if q == 27 {
            let corner: Float = 1.0 / 216
            add(SIMD3(1, 1, 1), corner); add(SIMD3(1, 1, -1), corner); add(SIMD3(1, -1, 1), corner); add(SIMD3(-1, 1, 1), corner)
        }
        return out
    }
}

enum LBMShaders {
    static func source(q: Int) -> String {
        let t = LBMVelocitySet.table(q: q)
        let cs = t.map { "int3(\($0.0.x),\($0.0.y),\($0.0.z))" }.joined(separator: ",")
        let ws = t.map { String(format: "%.10ff", $0.1) }.joined(separator: ",")
        let opp = (0..<q).map { i -> String in i == 0 ? "0" : String(i % 2 == 1 ? i + 1 : i - 1) }.joined(separator: ",")
        return "#include <metal_stdlib>\nusing namespace metal;\n#define Q \(q)\nconstant int3 C[Q] = {\(cs)};\nconstant float W[Q] = {\(ws)};\nconstant int OPP[Q] = {\(opp)};\n" + body
    }

    static let body = #"""
struct Params {
    int4 dim;        // nx, ny, nz, N
    int4 mode;       // collision (0 bgk, 1 trt/"mrt", 2 regularized), turbulence (0 none, 1 smag, 2 wale), interpolatedBB, rotorCount
    int4 mode2;      // partCount, spongeCells, hasGround, step
    float4 relax;    // omega0, tau0, smagorinsky Cs, WALE Cw
    float4 uFar;     // far-field velocity (lattice), w unused
    float4 accel;    // uniform frame acceleration (lattice / step), w = Smagorinsky wall-damping length (cells, 0 = off)
    float4 center;   // CoM in grid coordinates (cells), w = dx (m)
    float4 ground;   // x = ground plane y in grid coordinates, yzw = ground velocity (lattice)
    float4 misc;     // x sponge strength, y thin-part offset (m), z dt_lattice (s), w unused
};

struct GPart {
    float4 rot;      // world-from-part quaternion (xyz, w)
    float4 pos;      // part origin relative to CoM, metres; w = bound radius (m)
    float4 linVel;   // lattice units, relative to the domain frame
    float4 angVel;   // rad per lattice step (world axes); w = thin-part thickening offset (m)
    int4   grid;     // nx, ny, nz, offset into grid data
    float4 origin;   // part-local corner of the sdf grid (m), w = h (m)
    int4   flags;    // x thin, y disabled
};

static inline float3 qrot(float4 q, float3 v) { float3 t = 2.0f * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
static inline float3 qrotInv(float4 q, float3 v) { return qrot(float4(-q.xyz, q.w), v); }
static inline uint cellIndex(int3 g, int4 dim) { return uint(g.x + dim.x * (g.y + dim.y * g.z)); }
static inline bool inside(int3 g, int4 dim) { return all(g >= 0) && g.x < dim.x && g.y < dim.y && g.z < dim.z; }

static inline float feq(int i, float rho, float3 u) {
    float cu = dot(float3(C[i]), u);
    return W[i] * rho * (1.0f + 3.0f * cu + 4.5f * cu * cu - 1.5f * dot(u, u));
}

static float sampleGrid(device const float* grids, GPart p, float3 l) {
    float h = p.origin.w;
    float3 u = (l - p.origin.xyz) / h - 0.5f;
    float3 n = float3(p.grid.xyz);
    if (any(u < 0.0f) || any(u > n - 1.0f)) {
        // Outside the padded grid: distance to the grid box (always positive, ≥ 2h from the surface).
        float3 lo = p.origin.xyz, hi = p.origin.xyz + n * h;
        float3 dd = max(max(lo - l, l - hi), 0.0f);
        return length(dd) + 2.0f * h;
    }
    int3 i0 = min(int3(floor(u)), p.grid.xyz - 2);
    float3 fr = u - float3(i0);
    int nx = p.grid.x, ny = p.grid.y; int off = p.grid.w;
    #define G(a,b,c) grids[off + (i0.x + a) + nx * ((i0.y + b) + ny * (i0.z + c))]
    float c00 = mix(G(0,0,0), G(1,0,0), fr.x), c10 = mix(G(0,1,0), G(1,1,0), fr.x);
    float c01 = mix(G(0,0,1), G(1,0,1), fr.x), c11 = mix(G(0,1,1), G(1,1,1), fr.x);
    #undef G
    return mix(mix(c00, c10, fr.y), mix(c01, c11, fr.y), fr.z);
}

/// Velocity (lattice) of the wall owning solid cell g (part id pid; -2 = ground).
static inline float3 wallVelocity(int pid, float3 g, constant Params& P, device const GPart* parts) {
    if (pid == -2) return P.ground.yzw;
    if (pid < 0) return float3(0);
    GPart p = parts[pid];
    float3 r = g - (P.center.xyz + p.pos.xyz / P.center.w);
    return p.linVel.xyz + cross(p.angVel.xyz, r);
}

// ---------------------------------------------------------------- voxelise
/// Signed distance (m) of the scene (all parts + ground) at a point relative to the CoM; `part` = owner slot (-2 ground).
/// Each part is inflated by 0.3 of its sdf cell so zero-thickness sheets (trailing edges, panels) have a finite core.
static float sceneSDF(float3 pm, constant Params& P, device const GPart* parts, device const float* grids, thread int& part) {
    float dx = P.center.w;
    float best = 1e9f; part = -1;
    for (int k = 0; k < P.mode2.x; k++) {
        GPart p = parts[k];
        if (p.flags.y != 0) continue;
        float3 d = pm - p.pos.xyz;
        if (length(d) > p.pos.w + 2.0f * dx) continue;
        float s = sampleGrid(grids, p, qrotInv(p.rot, d)) - 0.3f * p.origin.w - p.angVel.w;
        if (s < best) { best = s; part = k; }
    }
    if (P.mode2.z != 0) {
        float sg = pm.y - (P.ground.x - P.center.y) * dx;
        if (sg < best) { best = sg; part = -2; }
    }
    return best;
}

/// Per cell: node sdf (cells), nearest part, and for near-wall fluid cells the wall crossing of every link
/// (sampled at 1/8 steps along x → x − c_i, so sheets thinner than a cell still cut the link).
/// link code: 0 = no wall; else low byte q·255 (1..255), high byte part slot + 1 (255 = ground).
kernel void lbmVoxelize(device float* sdf [[buffer(0)]], device short* pid [[buffer(1)]],
                        constant Params& P [[buffer(2)]], device const GPart* parts [[buffer(3)]],
                        device const float* grids [[buffer(4)]], device ushort* links [[buffer(5)]],
                        uint3 gid [[thread_position_in_grid]]) {
    int3 g = int3(gid);
    if (!inside(g, P.dim)) return;
    int N = P.dim.w;
    uint idx = cellIndex(g, P.dim);
    float dx = P.center.w;
    float3 pm = (float3(g) - P.center.xyz) * dx;
    int bp;
    float s0 = sceneSDF(pm, P, parts, grids, bp);
    sdf[idx] = s0 / dx;
    pid[idx] = short(bp);
    bool near = s0 > 0.0f && s0 < 2.0f * dx;
    for (int i = 0; i < Q; i++) {
        ushort code = 0;
        if (near && i > 0) {
            float3 step = -float3(C[i]) * dx;
            float sa = s0, ta = 0;
            for (int k = 1; k <= 8; k++) {
                float t = float(k) / 8.0f;
                int pk;
                float sb = sceneSDF(pm + t * step, P, parts, grids, pk);
                if (sb <= 0.0f) {
                    float q = ta + (t - ta) * sa / max(sa - sb, 1e-9f);
                    if (P.mode.z == 0) q = 0.5f;
                    uint qq = uint(clamp(q * 255.0f + 0.5f, 1.0f, 255.0f));
                    uint pc = pk == -2 ? 255u : uint(min(pk + 1, 254));
                    code = ushort(qq | (pc << 8));
                    break;
                }
                sa = sb; ta = t;
            }
        }
        links[i * N + idx] = code;
    }
}

// ---------------------------------------------------------------- init / rescale
kernel void lbmInit(device float* f [[buffer(0)]], constant Params& P [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
    if (int(gid) >= P.dim.w) return;
    for (int i = 0; i < Q; i++) f[i * P.dim.w + gid] = feq(i, 1.0f, P.uFar.xyz);
}

/// Changes the lattice time step by factor k (u_lat -> k·u_lat): f = feq(ρ, k·u) + k·(f − feq(ρ, u)).
kernel void lbmRescale(device float* f [[buffer(0)]], constant Params& P [[buffer(1)]], constant float& k [[buffer(2)]],
                       uint gid [[thread_position_in_grid]]) {
    if (int(gid) >= P.dim.w) return;
    int N = P.dim.w;
    float fl[Q]; float rho = 0; float3 m = 0;
    for (int i = 0; i < Q; i++) { fl[i] = f[i * N + gid]; rho += fl[i]; m += fl[i] * float3(C[i]); }
    float3 u = m / max(rho, 1e-6f);
    for (int i = 0; i < Q; i++) { float e = feq(i, rho, u); f[i * N + gid] = feq(i, rho, k * u) + k * (fl[i] - e); }
}

// ---------------------------------------------------------------- collide
kernel void lbmCollide(device float* f [[buffer(0)]], device float4* macroOut [[buffer(1)]],
                       device const float* sdf [[buffer(2)]], device const short* pidBuf [[buffer(3)]],
                       constant Params& P [[buffer(4)]], device const GPart* parts [[buffer(5)]],
                       device const float4* rotors [[buffer(6)]], device atomic_uint* stats [[buffer(7)]],
                       device const float4* macroIn [[buffer(8)]], uint3 gid [[thread_position_in_grid]]) {
    int3 g = int3(gid);
    if (!inside(g, P.dim)) return;
    int N = P.dim.w;
    uint idx = cellIndex(g, P.dim);
    if (sdf[idx] <= 0.0f) {
        // Solid: hold equilibrium at the wall velocity so freshly uncovered cells start sensibly.
        float3 uw = wallVelocity(pidBuf[idx], float3(g), P, parts);
        for (int i = 0; i < Q; i++) f[i * N + idx] = feq(i, 1.0f, uw);
        macroOut[idx] = float4(uw, -1.0f);   // w < 0 marks solid for viz / diagnostics
        return;
    }
    // Far-field faces: inflow faces (bit set in misc.w) are Dirichlet u∞ with a velocity sponge; all other faces are
    // open (zero-gradient in stream) with a pressure-only sponge, so circulation/downwash can leave the domain.
    int mask = int(P.misc.w);
    int dIn = 1 << 20, dOut = 1 << 20;
    for (int a = 0; a < 3; a++) {
        int lo = g[a], hi = P.dim[a] - 1 - g[a];
        if (mask & (1 << (2 * a))) dIn = min(dIn, lo); else dOut = min(dOut, lo);
        if (mask & (1 << (2 * a + 1))) dIn = min(dIn, hi); else dOut = min(dOut, hi);
    }
    float3 uF = P.uFar.xyz;
    if (dIn == 0) {
        for (int i = 0; i < Q; i++) f[i * N + idx] = feq(i, 1.0f, uF);
        macroOut[idx] = float4(uF, 1.0f);
        return;
    }
    if (dOut == 0) {   // open face: pressure outlet, equilibrium at ρ0 and the inward neighbour's velocity (prev step)
        int3 gi = clamp(g, int3(1), P.dim.xyz - 2);
        float4 mi = macroIn[cellIndex(gi, P.dim)];
        float3 uo = mi.w > 0 ? mi.xyz : uF;
        float lu = length(uo); if (lu > 0.3f) uo *= 0.3f / lu;
        for (int i = 0; i < Q; i++) f[i * N + idx] = feq(i, 1.0f, uo);
        macroOut[idx] = float4(uo, 1.0f);
        return;
    }
    float fl[Q];
    float rho = 0; float3 m = 0;
    for (int i = 0; i < Q; i++) { fl[i] = f[i * N + idx]; rho += fl[i]; m += fl[i] * float3(C[i]); }
    // Body force: frame acceleration + actuator disks (thrust + swirl).
    float3 F = rho * P.accel.xyz;
    float3 x = float3(g);
    for (int r = 0; r < P.mode.w; r++) {
        float4 c = rotors[3 * r], ax = rotors[3 * r + 1], sw = rotors[3 * r + 2];
        float3 d = x - c.xyz; float a = dot(d, ax.xyz);
        float hw = 1.0f - fabs(a) / sw.y;                      // axial hat, Σ over cells = 1
        if (hw <= 0.0f) continue;
        float3 rr = d - a * ax.xyz; float rad = length(rr);
        if (rad > c.w) continue;
        F += -ax.xyz * (ax.w * hw);                            // thrust reaction on the air
        if (rad > 1e-4f) F += normalize(cross(ax.xyz, rr)) * (sw.x * rad * hw);   // swirl
    }
    float3 u = (m + 0.5f * F) / max(rho, 1e-6f);
    float tau0 = P.relax.y;
    // Non-equilibrium stress Π_neq (symmetric: xx yy zz xy xz yz).
    float fe[Q]; float pxx = 0, pyy = 0, pzz = 0, pxy = 0, pxz = 0, pyz = 0;
    for (int i = 0; i < Q; i++) {
        fe[i] = feq(i, rho, u);
        float n = fl[i] - fe[i]; float3 cc = float3(C[i]);
        pxx += n * cc.x * cc.x; pyy += n * cc.y * cc.y; pzz += n * cc.z * cc.z;
        pxy += n * cc.x * cc.y; pxz += n * cc.x * cc.z; pyz += n * cc.y * cc.z;
    }
    float tau = tau0;
    if (P.mode.y == 1) {   // Smagorinsky (Hou et al. 1996), Δ = 1 cell
        float Qn = sqrt(pxx * pxx + pyy * pyy + pzz * pzz + 2.0f * (pxy * pxy + pxz * pxz + pyz * pyz));
        float cs2 = P.relax.z * P.relax.z;
        // Van Driest-style wall damping on the length scale (distance from the sdf, cells): (Cs·Δ·(1 − e^(−d/A)))².
        float dw = sdf[idx];
        float damp = P.accel.w > 0.0f ? 1.0f - exp(-max(dw, 0.0f) / P.accel.w) : 1.0f;
        cs2 *= damp * damp;
        tau = 0.5f * (tau0 + sqrt(tau0 * tau0 + 18.0f * 1.41421356f * cs2 * Qn / max(rho, 1e-6f)));
    } else if (P.mode.y == 2) {   // WALE (Nicoud & Ducros 1999) from the previous step's velocity field
        float3x3 gr;
        int3 ex[3] = {int3(1,0,0), int3(0,1,0), int3(0,0,1)};
        for (int b = 0; b < 3; b++) {
            int3 gp = clamp(g + ex[b], int3(0), P.dim.xyz - 1), gm = clamp(g - ex[b], int3(0), P.dim.xyz - 1);
            float3 up = macroIn[cellIndex(gp, P.dim)].xyz, um = macroIn[cellIndex(gm, P.dim)].xyz;
            gr[b] = 0.5f * (up - um);   // column b = ∂u/∂x_b
        }
        float3x3 g2 = gr * gr;
        float3x3 S = 0.5f * (gr + transpose(gr));
        float tr = (g2[0][0] + g2[1][1] + g2[2][2]) / 3.0f;
        float3x3 Sd = 0.5f * (g2 + transpose(g2));
        Sd[0][0] -= tr; Sd[1][1] -= tr; Sd[2][2] -= tr;
        float SS = 0, SdSd = 0;
        for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) { SS += S[a][b] * S[a][b]; SdSd += Sd[a][b] * Sd[a][b]; }
        float cw2 = P.relax.w * P.relax.w;
        float nut = cw2 * pow(SdSd, 1.5f) / (pow(SS, 2.5f) + pow(SdSd, 1.25f) + 1e-20f);
        tau = tau0 + 3.0f * nut;
    }
    tau = max(tau, 0.5005f);
    float om = 1.0f / tau;
    // Sponge toward the far field near the outer faces.
    float sig = 0, sigP = 0;
    if (dIn < P.mode2.y) { float s = 1.0f - float(dIn) / float(P.mode2.y); sig = P.misc.x * s * s; }
    if (dOut < P.mode2.y) { float s = 1.0f - float(dOut) / float(P.mode2.y); sigP = P.misc.x * s * s; }
    for (int i = 0; i < Q; i++) {
        float3 cc = float3(C[i]);
        float cu = dot(cc, u);
        float Si = (1.0f - 0.5f * om) * W[i] * dot(3.0f * (cc - u) + 9.0f * cu * cc, F);
        float post;
        if (P.mode.x == 2) {   // regularized: rebuild f_neq from its 2nd-order Hermite projection
            float qxx = cc.x * cc.x - 1.0f / 3.0f, qyy = cc.y * cc.y - 1.0f / 3.0f, qzz = cc.z * cc.z - 1.0f / 3.0f;
            float f1 = 4.5f * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0f * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
            post = fe[i] + (1.0f - om) * f1 + Si;
        } else if (P.mode.x == 1) {   // MRT in the Hermite basis: stress modes relax at ω, all higher (ghost) modes at 1.2
            float qxx = cc.x * cc.x - 1.0f / 3.0f, qyy = cc.y * cc.y - 1.0f / 3.0f, qzz = cc.z * cc.z - 1.0f / 3.0f;
            float f1 = 4.5f * W[i] * (qxx * pxx + qyy * pyy + qzz * pzz + 2.0f * (cc.x * cc.y * pxy + cc.x * cc.z * pxz + cc.y * cc.z * pyz));
            post = fe[i] + (1.0f - om) * f1 + (1.0f - 1.2f) * (fl[i] - fe[i] - f1) + Si;
        } else {
            post = fl[i] - om * (fl[i] - fe[i]) + Si;
        }
        if (sig > 0) post += sig * (feq(i, 1.0f, uF) - post);
        if (sigP > 0) post += sigP * (feq(i, 1.0f, u) - feq(i, rho, u));   // relax density only
        f[i * N + idx] = post;
    }
    macroOut[idx] = float4(u, rho);
    float ma = length(u) * 1.7320508f;
    if (isnan(ma) || isnan(rho)) { atomic_store_explicit(&stats[1], 1u, memory_order_relaxed); }
    else atomic_fetch_max_explicit(&stats[0], as_type<uint>(ma), memory_order_relaxed);
}

// ---------------------------------------------------------------- stream + walls + momentum exchange
kernel void lbmStream(device const float* fs [[buffer(0)]], device float* fn [[buffer(1)]],
                      device const float* sdf [[buffer(2)]], device const short* pidBuf [[buffer(3)]],
                      constant Params& P [[buffer(4)]], device const GPart* parts [[buffer(5)]],
                      device atomic_float* acc [[buffer(6)]], device const ushort* links [[buffer(7)]],
                      uint3 gid [[thread_position_in_grid]]) {
    int3 g = int3(gid);
    if (!inside(g, P.dim)) return;
    int N = P.dim.w;
    uint idx = cellIndex(g, P.dim);
    float sx = sdf[idx];
    if (sx <= 0.0f) { for (int i = 0; i < Q; i++) fn[i * N + idx] = fs[i * N + idx]; return; }
    int curPart = -1; float3 aF = 0, aT = 0;
    for (int i = 0; i < Q; i++) {
        int3 s = g - C[i];
        if (!inside(s, P.dim)) { fn[i * N + idx] = fs[i * N + idx]; continue; }   // boundary-shell cells are reset by collide
        uint sidx = cellIndex(s, P.dim);
        ushort code = links[i * N + idx];
        float q; int pid;
        if (code == 0) {
            if (sdf[sidx] > 0.0f) { fn[i * N + idx] = fs[i * N + sidx]; continue; }
            q = 0.5f; pid = pidBuf[sidx];             // solid neighbour without a sampled crossing (fallback)
        } else {
            q = float(code & 255u) / 255.0f;
            uint pc = code >> 8; pid = pc == 255u ? -2 : int(pc) - 1;
        }
        q = clamp(q, 0.02f, 0.98f);
        // Link crosses a wall: bounce-back of the population leaving x toward the wall.
        int o = OPP[i];
        float fo = fs[o * N + idx];
        float3 ci = float3(C[i]);
        float3 wp = float3(g) - q * ci;
        float3 uw = wallVelocity(pid, wp, P, parts);
        float mw = 6.0f * W[i] * dot(ci, uw);
        float v;
        if (q < 0.5f) {
            int3 x2 = g + C[i];
            if (inside(x2, P.dim) && sdf[cellIndex(x2, P.dim)] > 0.0f && links[o * N + idx] == 0)
                v = 2.0f * q * fo + (1.0f - 2.0f * q) * fs[o * N + cellIndex(x2, P.dim)] + mw;
            else v = fo + mw;
        } else {
            v = fo / (2.0f * q) + (2.0f * q - 1.0f) / (2.0f * q) * fs[i * N + idx] + mw / (2.0f * q);
        }
        fn[i * N + idx] = v;
        if (pid >= 0) {
            // Galilean-invariant momentum exchange (Wen et al. 2014): ΔP_body = f_o(c_o − u_w) − f_i(c_i − u_w).
            // Populations are taken relative to the rest state w_i·ρ0 (ρ0 = 1): a closed surface is unchanged, but a
            // part whose surface is partly buried in another part (open link set) no longer feels the ambient
            // pressure ρ0·c_s² on its exposed side only (that gave ±50 kN per part on the overlapping Trainer).
            float3 dP = (fo - W[i]) * (-ci - uw) - (v - W[i]) * (ci - uw);
            float3 tq = cross(wp - P.center.xyz, dP);
            if (curPart < 0) curPart = pid;
            if (pid == curPart) { aF += dP; aT += tq; }
            else {
                device atomic_float* a = acc + 6 * pid;
                atomic_fetch_add_explicit(a + 0, dP.x, memory_order_relaxed); atomic_fetch_add_explicit(a + 1, dP.y, memory_order_relaxed);
                atomic_fetch_add_explicit(a + 2, dP.z, memory_order_relaxed); atomic_fetch_add_explicit(a + 3, tq.x, memory_order_relaxed);
                atomic_fetch_add_explicit(a + 4, tq.y, memory_order_relaxed); atomic_fetch_add_explicit(a + 5, tq.z, memory_order_relaxed);
            }
        }
    }
    if (curPart >= 0) {
        device atomic_float* a = acc + 6 * curPart;
        atomic_fetch_add_explicit(a + 0, aF.x, memory_order_relaxed); atomic_fetch_add_explicit(a + 1, aF.y, memory_order_relaxed);
        atomic_fetch_add_explicit(a + 2, aF.z, memory_order_relaxed); atomic_fetch_add_explicit(a + 3, aT.x, memory_order_relaxed);
        atomic_fetch_add_explicit(a + 4, aT.y, memory_order_relaxed); atomic_fetch_add_explicit(a + 5, aT.z, memory_order_relaxed);
    }
}

// ---------------------------------------------------------------- diagnostics: Σρ and fluid-cell count
kernel void lbmMass(device const float4* macro [[buffer(0)]], constant Params& P [[buffer(1)]], device atomic_float* out [[buffer(2)]],
                    uint gid [[thread_position_in_grid]], uint lid [[thread_index_in_threadgroup]], uint tg [[threads_per_threadgroup]],
                    uint sl [[thread_index_in_simdgroup]]) {
    float r = 0, c = 0;
    if (int(gid) < P.dim.w) { float4 m = macro[gid]; if (m.w > 0) { r = m.w; c = 1; } }
    r = simd_sum(r); c = simd_sum(c);
    if (sl == 0) { atomic_fetch_add_explicit(&out[0], r, memory_order_relaxed); atomic_fetch_add_explicit(&out[1], c, memory_order_relaxed); }
}

// ---------------------------------------------------------------- visualisation
static float3 turbo(float t) {
    t = clamp(t, 0.0f, 1.0f);
    const float4 kr = float4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const float4 kg = float4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const float4 kb = float4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const float2 kr2 = float2(-152.94239396, 59.28637943), kg2 = float2(4.27729857, 2.82956604), kb2 = float2(-89.90310912, 27.34824973);
    float4 v4 = float4(1.0, t, t * t, t * t * t); float2 v2 = v4.zw * v4.z;
    return clamp(float3(dot(v4, kr) + dot(v2, kr2), dot(v4, kg) + dot(v2, kg2), dot(v4, kb) + dot(v2, kb2)), 0.0f, 1.0f);
}

/// Slice through the domain: axis 0 → (y,z) plane at x = layer, 1 → (x,z) at y, 2 → (x,y) at z.
/// field 0 speed (|u + frame| / scale), 1 pressure (diverging), 2 vorticity magnitude.
kernel void lbmSlice(device const float4* macro [[buffer(0)]], constant Params& P [[buffer(1)]], constant int4& sl [[buffer(2)]],
                     constant float4& scale [[buffer(3)]], device atomic_uint* range [[buffer(4)]],
                     texture2d<float, access::write> tex [[texture(0)]], uint2 t [[thread_position_in_grid]]) {
    // scale.x = colour-map top in raw lattice units (auto-ranged on the CPU from the previous frame's max, written to
    // `range` here as float bits — non-negative floats order like uints, so atomic max works).
    if (t.x >= tex.get_width() || t.y >= tex.get_height()) return;
    int3 g = sl.x == 0 ? int3(sl.y, int(t.x), int(t.y)) : (sl.x == 1 ? int3(int(t.x), sl.y, int(t.y)) : int3(int(t.x), int(t.y), sl.y));
    if (!inside(g, P.dim)) { tex.write(float4(0), t); return; }
    float4 m = macro[cellIndex(g, P.dim)];
    if (m.w < 0) { tex.write(float4(0.08, 0.08, 0.09, 1), t); return; }
    float r, v;
    float top = max(scale.x, 1e-9f);
    if (sl.z == 0) { r = length(m.xyz + scale.yzw); v = r / top; }
    else if (sl.z == 1) { float dp = (m.w - 1.0f) / 3.0f; r = fabs(dp); v = 0.5f + 0.5f * dp / top; }
    else {
        float3 d[3];
        int3 ex[3] = {int3(1,0,0), int3(0,1,0), int3(0,0,1)};
        for (int b = 0; b < 3; b++) {
            int3 gp = clamp(g + ex[b], int3(0), P.dim.xyz - 1), gm = clamp(g - ex[b], int3(0), P.dim.xyz - 1);
            d[b] = 0.5f * (macro[cellIndex(gp, P.dim)].xyz - macro[cellIndex(gm, P.dim)].xyz);
        }
        float3 w = float3(d[1].z - d[2].y, d[2].x - d[0].z, d[0].y - d[1].x);
        r = length(w); v = r / top;
    }
    if (isfinite(r)) atomic_fetch_max_explicit(range, as_type<uint>(r), memory_order_relaxed);
    tex.write(float4(turbo(clamp(v, 0.0f, 1.0f)), 0.85), t);
}

/// Massless tracers (grid coordinates), advected with the lattice velocity for `steps` steps; respawn on exit.
kernel void lbmParticles(device float4* p [[buffer(0)]], device const float4* macro [[buffer(1)]], constant Params& P [[buffer(2)]],
                         constant float& steps [[buffer(3)]], uint gid [[thread_position_in_grid]], constant uint& count [[buffer(4)]]) {
    if (gid >= count) return;
    float4 q = p[gid];
    int3 g = int3(round(q.xyz));
    bool ok = inside(g, P.dim);
    float4 m = ok ? macro[cellIndex(g, P.dim)] : float4(0, 0, 0, -1);
    if (ok && m.w > 0) { q.xyz += m.xyz * steps; q.w += steps; }
    g = int3(round(q.xyz));
    if (!inside(g, P.dim) || m.w <= 0 || q.w > 4.0f * float(P.dim.x + P.dim.y + P.dim.z)) {
        // Respawn on the upstream side: hash → random point, pushed back against the far-field flow.
        uint h = gid * 747796405u + uint(P.mode2.w) * 2891336453u;
        h ^= h >> 16; h *= 2246822519u; h ^= h >> 13;
        float3 r = float3(float(h & 1023u), float((h >> 10) & 1023u), float((h >> 20) & 1023u)) / 1023.0f;
        float3 dimf = float3(P.dim.xyz) - 3.0f;
        float3 np = 1.0f + r * dimf;
        float3 uf = P.uFar.xyz; float lu = length(uf);
        if (lu > 1e-6f) {
            float3 dir = uf / lu;
            int ax = fabs(dir.x) > fabs(dir.y) ? (fabs(dir.x) > fabs(dir.z) ? 0 : 2) : (fabs(dir.y) > fabs(dir.z) ? 1 : 2);
            np[ax] = dir[ax] > 0 ? 2.0f : dimf[ax];
        }
        q = float4(np, 0);
    }
    p[gid] = q;
}
"""#
}
