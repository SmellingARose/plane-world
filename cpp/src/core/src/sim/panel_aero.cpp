#include "pw/sim/panel_aero.h"
#include <cmath>
#include <cstring>
#include <limits>

namespace pw::sim {

static inline double fminx(double a, double b) { return std::fmin(a, b); }
static inline double fmaxx(double a, double b) { return std::fmax(a, b); }
static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline int floorInt(double v) { return int(std::floor(v)); }

PanelMesh::PanelMesh(const std::vector<Vec3d>& soup) {
    constexpr double inf = std::numeric_limits<double>::infinity();
    Vec3d bmin{inf, inf, inf}, bmax{-inf, -inf, -inf};
    std::size_t i = 0;
    while (i + 2 < soup.size()) {
        Vec3d p0 = soup[i], p1 = soup[i + 1], p2 = soup[i + 2]; i += 3;
        Vec3d cr = cross(p1 - p0, p2 - p0);
        double l = length(cr);
        if (l < 1e-12) continue;
        centers_.push_back((p0 + p1 + p2) / 3);
        normals_.push_back(cr / l);
        areas_.push_back(0.5 * l);
        tris_.push_back({p0, p1, p2});
        for (const Vec3d& p : {p0, p1, p2}) {
            bmin = {fminx(bmin.x, p.x), fminx(bmin.y, p.y), fminx(bmin.z, p.z)};
            bmax = {fmaxx(bmax.x, p.x), fmaxx(bmax.y, p.y), fmaxx(bmax.z, p.z)};
        }
    }
    if (!centers_.empty()) {
        Vec3d e = bmax - bmin;
        refL_ = smax(0.05, fmaxx(fmaxx(e.x, e.y), e.z));
    }
    shadowed_.assign(centers_.size(), 0);
    double vol = 0;
    for (auto& t : tris_) vol += dot(t.a, cross(t.b, t.c));
    flipped_ = vol < 0;
    oriented_.reserve(normals_.size());
    for (auto& n : normals_) oriented_.push_back(flipped_ ? -n : n);
    grid_ = int(clamp(std::sqrt(double(count())) * 1.5, 16, 256));
    for (std::size_t k = 0; k < centers_.size(); ++k) {
        sx_.push_back(centers_[k].x); sy_.push_back(centers_[k].y); sz_.push_back(centers_[k].z);
        snx_.push_back(oriented_[k].x); sny_.push_back(oriented_[k].y); snz_.push_back(oriented_[k].z);
    }
    out_.assign(centers_.size() * 7, 0.0);
    washX_.assign(centers_.size(), 0.0); washY_.assign(centers_.size(), 0.0); washZ_.assign(centers_.size(), 0.0);
    depth_.assign(std::size_t(grid_) * std::size_t(grid_), inf);
}

void PanelMesh::updateShadows(const Vec3d& u) {
    if (count() == 0) return;
    if (dot(u, cachedFlow_) > std::cos(3 * kDeg)) return;
    cachedFlow_ = u; ++rebuilds_;
    Vec3d a = std::fabs(u.x) < 0.9 ? Vec3d{1, 0, 0} : Vec3d{0, 1, 0};
    Vec3d e1 = normalize(cross(u, a)), e2 = cross(u, e1);
    const int G = grid_;
    constexpr double inf = std::numeric_limits<double>::infinity();
    double loX = inf, loY = inf, hiX = -inf, hiY = -inf;
    for (auto& c : centers_) {
        double qx = dot(c, e1), qy = dot(c, e2);
        loX = fminx(loX, qx); loY = fminx(loY, qy); hiX = fmaxx(hiX, qx); hiY = fmaxx(hiY, qy);
    }
    double extX = fmaxx(hiX - loX, 1e-6) * 1.0001, extY = fmaxx(hiY - loY, 1e-6) * 1.0001;
    double cellX = extX / double(G), cellY = extY / double(G);
    std::fill(depth_.begin(), depth_.end(), inf);
    for (int k = 0; k < count(); ++k) {
        double d = dot(centers_[std::size_t(k)], u);
        const Tri& t = tris_[std::size_t(k)];
        double q0x = dot(t.a, e1), q0y = dot(t.a, e2), q1x = dot(t.b, e1), q1y = dot(t.b, e2), q2x = dot(t.c, e1), q2y = dot(t.c, e2);
        double mnx = fminx(fminx(q0x, q1x), q2x), mny = fminx(fminx(q0y, q1y), q2y);
        double mxx = fmaxx(fmaxx(q0x, q1x), q2x), mxy = fmaxx(fmaxx(q0y, q1y), q2y);
        int i0 = clampi(floorInt((mnx - loX) / cellX), 0, G - 1), i1 = clampi(floorInt((mxx - loX) / cellX), 0, G - 1);
        int j0 = clampi(floorInt((mny - loY) / cellY), 0, G - 1), j1 = clampi(floorInt((mxy - loY) / cellY), 0, G - 1);
        for (int j = j0; j <= j1; ++j)
            for (int i = i0; i <= i1; ++i) { double& dd = depth_[std::size_t(j * G + i)]; if (d < dd) dd = d; }
    }
    double tol = refL_ * 0.02;
    for (int k = 0; k < count(); ++k) {
        const Vec3d& c = centers_[std::size_t(k)];
        double qx = dot(c, e1), qy = dot(c, e2);
        int i = clampi(floorInt((qx - loX) / cellX), 0, G - 1), j = clampi(floorInt((qy - loY) / cellY), 0, G - 1);
        double d = dot(c, u);
        shadowed_[std::size_t(k)] = dot(oriented_[std::size_t(k)], u) < 0 && d > depth_[std::size_t(j * G + i)] + tol + std::sqrt(areas_[std::size_t(k)]);
    }
}

simdk::PanelSoA PanelMesh::soa() const {
    return {sx_.data(), sy_.data(), sz_.data(), snx_.data(), sny_.data(), snz_.data(), areas_.data(), shadowed_.data()};
}

namespace {
simdk::PanelParams params(const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel, const Vec3d& angVel,
                          const Vec3d& wind, double rho, double nu, double sos, double refL) {
    simdk::PanelParams p;
    p.qx = q.x; p.qy = q.y; p.qz = q.z; p.qw = q.w;
    p.ox = origin.x; p.oy = origin.y; p.oz = origin.z;
    p.comx = com.x; p.comy = com.y; p.comz = com.z;
    p.vx = linVel.x; p.vy = linVel.y; p.vz = linVel.z;
    p.wx = angVel.x; p.wy = angVel.y; p.wz = angVel.z;
    p.windx = wind.x; p.windy = wind.y; p.windz = wind.z;
    p.rho = rho; p.nu = nu; p.sos = sos; p.refL = refL;
    return p;
}
}

ForceTorque PanelMesh::accumulate(int lo, int hi) const {
    // Sum in panel order exactly like the scalar loop (F += f; T += cross(r, f)), skipping |v_rel| < 0.05 panels.
    Vec3d F, T;
    const double* o = out_.data();
    for (int k = lo; k < hi; ++k) {
        const double* r = o + 7 * k;
        if (r[6] == 0) continue;
        F += Vec3d{r[0], r[1], r[2]};
        T += Vec3d{r[3], r[4], r[5]};
    }
    return {F, T};
}

ForceTorque PanelMesh::evaluate(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel,
                                const Vec3d& angVel, const Vec3d& wind, double rho, double nu, double sos) const {
    if (hi <= lo) return {};
    simdk::PanelParams p = params(q, origin, com, linVel, angVel, wind, rho, nu, sos, refL_);
    simdk::panelKernel()(soa(), p, lo, hi, out_.data());
    return accumulate(lo, hi);
}

ForceTorque PanelMesh::evaluate(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel,
                                const Vec3d& angVel, const Vec3d& wind, const PanelWash& wash, double rho, double nu, double sos) const {
    if (hi <= lo) return {};
    for (int k = lo; k < hi; ++k) {
        Vec3d w = wash.velocity(origin + q.act(centers_[std::size_t(k)]));
        washX_[std::size_t(k)] = w.x; washY_[std::size_t(k)] = w.y; washZ_[std::size_t(k)] = w.z;
    }
    simdk::PanelParams p = params(q, origin, com, linVel, angVel, wind, rho, nu, sos, refL_);
    p.washX = washX_.data(); p.washY = washY_.data(); p.washZ = washZ_.data();
    simdk::panelKernel()(soa(), p, lo, hi, out_.data());
    return accumulate(lo, hi);
}

PanelBreakdown PanelMesh::breakdown(const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel, const Vec3d& angVel,
                                    const Vec3d& wind, const PanelWash* wash, double rho, double nu, double sos) const {
    PanelBreakdown b; b.panels = count();
    int nRe = 0;
    for (int k = 0; k < count(); ++k) {
        Vec3d pw = origin + q.act(centers_[std::size_t(k)]);
        Vec3d ws = wash ? wash->velocity(pw) : Vec3d{};
        double wl = length(ws); b.washMean += wl; b.washMax = smax(b.washMax, wl);
        Vec3d vrel = linVel + cross(angVel, pw - com) - (wind + ws);
        double sp = length(vrel);
        if (sp < 0.05) continue;
        Vec3d u = -vrel / sp, n = q.act(oriented_[std::size_t(k)]);
        double qdyn = 0.5 * rho * sp * sp, A = areas_[std::size_t(k)], c = dot(n, u);
        b.maxQ = smax(b.maxQ, qdyn);
        if (c < 0) {
            b.windward += 1;
            if (!shadowed_[std::size_t(k)]) { double M = sp / sos; b.pressure -= n * ((1 + M * M / 4) * c * c * qdyn * A); }
            else b.shadowedWindward += 1;
        } else b.pressure += n * (0.25 * c * qdyn * A);
        Vec3d tang = u - n * c;
        double tl = length(tang);
        if (tl > 1e-6) {
            double re = smax(1e4, sp * refL_ / nu), cf = 0.455 / std::pow(std::log10(re), 2.58);
            b.friction += tang / tl * (cf * qdyn * A * tl); b.meanRe += re; b.meanCf += cf; nRe += 1;
        }
    }
    if (nRe > 0) { b.meanRe /= double(nRe); b.meanCf /= double(nRe); }
    if (count() > 0) b.washMean /= double(count());
    return b;
}

std::optional<std::vector<Vec3d>> PanelMesh::decodePrototypeCAD(std::string_view s, double scale) {
    // Base64 with unknown characters ignored (Foundation .ignoreUnknownCharacters); '=' ends the data.
    auto val = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::vector<uint8_t> data;
    data.reserve(s.size() * 3 / 4);
    uint32_t acc = 0; int bits = 0;
    for (char c : s) {
        if (c == '=') break;
        int v = val(c);
        if (v < 0) continue;
        acc = (acc << 6) | uint32_t(v); bits += 6;
        if (bits >= 8) { bits -= 8; data.push_back(uint8_t((acc >> bits) & 0xFF)); }
    }
    if (data.size() < 36) return std::nullopt;
    std::size_t n = data.size() / 4;
    std::vector<Vec3d> out;
    out.reserve(n / 3);
    auto f32 = [&](std::size_t i) {
        uint32_t u = uint32_t(data[i * 4]) | uint32_t(data[i * 4 + 1]) << 8 | uint32_t(data[i * 4 + 2]) << 16 | uint32_t(data[i * 4 + 3]) << 24;
        float f; std::memcpy(&f, &u, 4); return double(f);
    };
    for (std::size_t i = 0; i + 2 < n; i += 3) out.push_back(Vec3d{f32(i), f32(i + 1), f32(i + 2)} * scale);
    return out;
}

std::vector<Vec3d> PanelMesh::boxSoup(const Vec3d& c, const Vec3d& s, const Quatd& q) {
    Vec3d h = s * 0.5;
    auto v = [&](double x, double y, double z) { return c + q.act({x * h.x, y * h.y, z * h.z}); };
    const Vec3d faces[6][4] = {
        {v(1, -1, -1), v(1, 1, -1), v(1, 1, 1), v(1, -1, 1)}, {v(-1, -1, 1), v(-1, 1, 1), v(-1, 1, -1), v(-1, -1, -1)},
        {v(-1, 1, -1), v(-1, 1, 1), v(1, 1, 1), v(1, 1, -1)}, {v(-1, -1, 1), v(-1, -1, -1), v(1, -1, -1), v(1, -1, 1)},
        {v(-1, -1, 1), v(1, -1, 1), v(1, 1, 1), v(-1, 1, 1)}, {v(1, -1, -1), v(-1, -1, -1), v(-1, 1, -1), v(1, 1, -1)}};
    std::vector<Vec3d> out;
    out.reserve(36);
    for (auto& f : faces) { out.push_back(f[0]); out.push_back(f[1]); out.push_back(f[2]); out.push_back(f[0]); out.push_back(f[2]); out.push_back(f[3]); }
    return out;
}

} // namespace pw::sim
