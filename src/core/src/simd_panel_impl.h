// Generic panel-aero kernel over a lane backend B (included by each simd_<isa>.cpp inside an anonymous namespace).
// Mirrors pw::sim::PanelMesh::evaluate operation for operation; see pw/simd_kernels.h for the exactness rules.
//
// Backend B provides: V (lane vector), M (lane mask), N (lane count), set1, load, store, add, sub, mul, div, fma
// (a*b+c, single rounding), sqrt, lt, gt, ge, sel(m, a, b) = m ? a : b, andnot(a, b) = !a && b, notm, maskFromBytes.

template <class B>
struct LV3 { typename B::V x, y, z; };

template <class B>
inline LV3<B> lcross(const LV3<B>& a, const LV3<B>& b) {
    using V = typename B::V;
    const V m1 = B::set1(-1.0);
    return {B::fma(a.y, b.z, B::mul(B::mul(a.z, b.y), m1)), B::fma(a.z, b.x, B::mul(B::mul(a.x, b.z), m1)),
            B::fma(a.x, b.y, B::mul(B::mul(a.y, b.x), m1))};
}
template <class B>
inline typename B::V ldot(const LV3<B>& a, const LV3<B>& b) { return B::add(B::add(B::mul(a.x, b.x), B::mul(a.y, b.y)), B::mul(a.z, b.z)); }

/// Quatd::act (Apple arm64 simd_act) with a scalar quaternion broadcast over the lanes.
template <class B>
inline LV3<B> lact(double qx, double qy, double qz, double qw, const LV3<B>& v) {
    using V = typename B::V;
    // conj(q) = (-qx, -qy, -qz, qw); A = (c.w, -c.z, c.y, -c.x), B = (c.z, c.w, -c.x, -c.y), C = (-c.y, c.x, c.w, -c.z)
    const double cx = -qx, cy = -qy, cz = -qz, cw = qw;
    const double A[4] = {cw, -cz, cy, -cx}, Bc[4] = {cz, cw, -cx, -cy}, C[4] = {-cy, cx, cw, -cz};
    V t[4];
    for (int i = 0; i < 4; ++i) t[i] = B::fma(v.z, B::set1(C[i]), B::fma(v.x, B::set1(A[i]), B::mul(v.y, B::set1(Bc[i]))));
    // r = q * t: A2 = (t.w, -t.z, t.y, -t.x), B2 = (t.z, t.w, -t.x, -t.y), C2 = (-t.y, t.x, t.w, -t.z), D2 = t
    const V m1 = B::set1(-1.0);
    const V ntx = B::mul(t[0], m1), nty = B::mul(t[1], m1), ntz = B::mul(t[2], m1);
    const V A2[3] = {t[3], ntz, t[1]}, B2[3] = {t[2], t[3], ntx}, C2[3] = {nty, t[0], t[3]};
    const V QX = B::set1(qx), QY = B::set1(qy), QZ = B::set1(qz), QW = B::set1(qw);
    V r[3];
    for (int i = 0; i < 3; ++i) r[i] = B::add(B::fma(QX, A2[i], B::mul(QY, B2[i])), B::fma(QZ, C2[i], B::mul(QW, t[i])));
    return {r[0], r[1], r[2]};
}

template <class B>
inline void panelsImpl(const pw::simdk::PanelSoA& m, const pw::simdk::PanelParams& p, int lo, int hi, double* out) {
    using V = typename B::V;
    using M = typename B::M;
    constexpr int N = B::N;
    const V zero = B::set1(0.0);
    const V ox = B::set1(p.ox), oy = B::set1(p.oy), oz = B::set1(p.oz);
    const V cmx = B::set1(p.comx), cmy = B::set1(p.comy), cmz = B::set1(p.comz);
    const LV3<B> lin{B::set1(p.vx), B::set1(p.vy), B::set1(p.vz)};
    const LV3<B> ang{B::set1(p.wx), B::set1(p.wy), B::set1(p.wz)};
    const V windx = B::set1(p.windx), windy = B::set1(p.windy), windz = B::set1(p.windz);
    const V half = B::set1(0.5), rho = B::set1(p.rho), sos = B::set1(p.sos), quarter = B::set1(0.25), one = B::set1(1.0), four = B::set1(4.0);
    const V refL = B::set1(p.refL), nu = B::set1(p.nu), reMin = B::set1(1e4), spMin = B::set1(0.05), tlMin = B::set1(1e-6);
    const V k455 = B::set1(0.455);
    int k = lo;
    for (; k + N <= hi; k += N) {
        LV3<B> c{B::load(m.cx + k), B::load(m.cy + k), B::load(m.cz + k)};
        LV3<B> nb{B::load(m.nx + k), B::load(m.ny + k), B::load(m.nz + k)};
        V A = B::load(m.area + k);
        M sh = B::maskFromBytes(m.shadowed + k);
        LV3<B> qc = lact<B>(p.qx, p.qy, p.qz, p.qw, c);
        LV3<B> pw{B::add(ox, qc.x), B::add(oy, qc.y), B::add(oz, qc.z)};
        LV3<B> r{B::sub(pw.x, cmx), B::sub(pw.y, cmy), B::sub(pw.z, cmz)};
        LV3<B> cr = lcross<B>(ang, r);
        LV3<B> vrel;
        if (p.washX) {
            V wx = B::add(windx, B::load(p.washX + k)), wy = B::add(windy, B::load(p.washY + k)), wz = B::add(windz, B::load(p.washZ + k));
            vrel = {B::sub(B::add(lin.x, cr.x), wx), B::sub(B::add(lin.y, cr.y), wy), B::sub(B::add(lin.z, cr.z), wz)};
        } else {
            vrel = {B::sub(B::add(lin.x, cr.x), windx), B::sub(B::add(lin.y, cr.y), windy), B::sub(B::add(lin.z, cr.z), windz)};
        }
        V sp = B::sqrt(ldot<B>(vrel, vrel));
        M valid = B::notm(B::lt(sp, spMin));   // scalar: if sp < 0.05 { continue } (a NaN speed is not skipped)
        LV3<B> u{B::div(B::sub(zero, vrel.x), sp), B::div(B::sub(zero, vrel.y), sp), B::div(B::sub(zero, vrel.z), sp)};
        LV3<B> n = lact<B>(p.qx, p.qy, p.qz, p.qw, nb);
        V qdyn = B::mul(B::mul(B::mul(half, rho), sp), sp);
        V cc = ldot<B>(n, u);
        M windward = B::lt(cc, zero);
        // windward, not shadowed: f = 0 - n * (cpmax*c*c*qdyn*A), cpmax = 1 + M*M/4
        V Mach = B::div(sp, sos);
        V cpmax = B::add(one, B::div(B::mul(Mach, Mach), four));
        V sw = B::mul(B::mul(B::mul(B::mul(cpmax, cc), cc), qdyn), A);
        // leeward: f = 0 + n * (0.25*c*qdyn*A)
        V sl = B::mul(B::mul(B::mul(quarter, cc), qdyn), A);
        LV3<B> fw{B::sub(zero, B::mul(n.x, sw)), B::sub(zero, B::mul(n.y, sw)), B::sub(zero, B::mul(n.z, sw))};
        LV3<B> fl{B::add(zero, B::mul(n.x, sl)), B::add(zero, B::mul(n.y, sl)), B::add(zero, B::mul(n.z, sl))};
        M press = B::andnot(sh, windward);   // windward && !shadowed
        LV3<B> f{B::sel(windward, B::sel(press, fw.x, zero), fl.x), B::sel(windward, B::sel(press, fw.y, zero), fl.y),
                 B::sel(windward, B::sel(press, fw.z, zero), fl.z)};
        // skin friction: tang = u - n*c; if |tang| > 1e-6: f += tang/tl * (cf*qdyn*A*tl)
        LV3<B> tang{B::sub(u.x, B::mul(n.x, cc)), B::sub(u.y, B::mul(n.y, cc)), B::sub(u.z, B::mul(n.z, cc))};
        V tl = B::sqrt(ldot<B>(tang, tang));
        M fric = B::gt(tl, tlMin);
        V re = B::div(B::mul(sp, refL), nu);
        re = B::sel(B::ge(re, reMin), re, reMin);   // Swift max(1e4, re) = re >= 1e4 ? re : 1e4
        alignas(64) double reL[N], pl[N];
        B::store(reL, re);
        for (int j = 0; j < N; ++j) pl[j] = std::pow(std::log10(reL[j]), 2.58);
        V cf = B::div(k455, B::load(pl));
        V kf = B::mul(B::mul(B::mul(cf, qdyn), A), tl);
        LV3<B> ff{B::add(f.x, B::mul(B::div(tang.x, tl), kf)), B::add(f.y, B::mul(B::div(tang.y, tl), kf)), B::add(f.z, B::mul(B::div(tang.z, tl), kf))};
        f = {B::sel(fric, ff.x, f.x), B::sel(fric, ff.y, f.y), B::sel(fric, ff.z, f.z)};
        LV3<B> t = lcross<B>(r, f);
        // Skipped panels (|v_rel| < 0.05) report zeros, like the scalar kernel.
        f = {B::sel(valid, f.x, zero), B::sel(valid, f.y, zero), B::sel(valid, f.z, zero)};
        t = {B::sel(valid, t.x, zero), B::sel(valid, t.y, zero), B::sel(valid, t.z, zero)};
        alignas(64) double o[7][N];
        B::store(o[0], f.x); B::store(o[1], f.y); B::store(o[2], f.z);
        B::store(o[3], t.x); B::store(o[4], t.y); B::store(o[5], t.z);
        B::store(o[6], B::sel(valid, one, zero));
        for (int j = 0; j < N; ++j)
            for (int q = 0; q < 7; ++q) out[7 * (k + j) + q] = o[q][j];
    }
    if (k < hi) pw::simdk::detail::panelsScalar(m, p, k, hi, out);
}
