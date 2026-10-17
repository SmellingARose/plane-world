// Buoyancy + hydrodynamic forces on triangle hulls (Sources/Water/Hydrodynamics.swift) and splash spray
// (Sources/Water/SplashSystem.swift).
//  * Each triangle is clipped against the water surface using per-vertex signed heights (y - eta(x, z)).
//  * Hydrostatic pressure is linear over each sub-triangle: force from the centroid depth, moment from the exact
//    linear x linear integral A/12 (sum p_i r_i + sum p sum r); a closed hull in calm water gives Archimedes exactly.
//  * Hydrodynamic: pressure drag on advancing faces, weaker suction on receding faces, ITTC-1957 skin friction,
//    linear radiation damping. Fast surface entry emits splash.
// Large hulls split the triangle pass over the JobSystem with a fixed chunking, so results do not depend on the
// thread count; partial sums are reduced in chunk order.
#include <algorithm>
#include <cmath>
#include "pw/env/water.h"
#include "pw/jobs.h"

namespace pw::water {

namespace hydro {
int parallelTriangleThreshold = 8192;
int parallelVertexThreshold = 4096;

double signedVolume(const HullMesh& hull) {
    double v = 0;
    const auto& P = hull.positions;
    const auto& I = hull.indices;
    for (std::size_t t = 0; t + 2 < I.size(); t += 3) {
        Vec3d a{P[I[t] * 3], P[I[t] * 3 + 1], P[I[t] * 3 + 2]}, b{P[I[t + 1] * 3], P[I[t + 1] * 3 + 1], P[I[t + 1] * 3 + 2]},
              c{P[I[t + 2] * 3], P[I[t + 2] * 3 + 1], P[I[t + 2] * 3 + 2]};
        v += dot(a, cross(b, c));
    }
    return v / 6;
}

namespace {
using Partial = HydroScratch::Partial;
struct Ctx {
    double rho, g; Vec3d com; const BodyState* state; Vec3d waterVel; double lengthRef; const HydroSettings* s;
};
inline Vec3d velocityAt(const BodyState& st, const Vec3d& p) { return st.linearVelocity + cross(st.angularVelocity, p - st.centerOfMass); }

inline void subTriangle(const Vec3d& a, const Vec3d& b, const Vec3d& c, double ha, double hb, double hc, const Ctx& k, bool partial, Partial& acc) {
    Vec3d cr = cross(b - a, c - a);
    double len = length(cr);
    if (!(len > 1e-14)) return;
    double area = 0.5 * len;
    Vec3d nrm = cr / len;
    double pa = k.rho * k.g * std::max(ha, 0.0), pb = k.rho * k.g * std::max(hb, 0.0), pc = k.rho * k.g * std::max(hc, 0.0);
    double pMean = (pa + pb + pc) / 3;
    Vec3d F = nrm * (-pMean * area);
    Vec3d ra = a - k.com, rb = b - k.com, rc = c - k.com;
    Vec3d M = (ra * pa + rb * pb + rc * pc + (ra + rb + rc) * (pa + pb + pc)) * (area / 12);
    acc.force = acc.force + F;
    acc.torque = acc.torque - cross(M, nrm);
    acc.volume += (ha + hb + hc) / 3 * area * (-nrm.y);
    acc.wetted += area;
    Vec3d cen = (a + b + c) / 3;
    Vec3d v = velocityAt(*k.state, cen) - k.waterVel;
    double vn = dot(v, nrm);
    const HydroSettings& s = *k.s;
    double cd = vn > 0 ? s.pressureDragCoefficient : s.suctionCoefficient;
    Vec3d Fd = nrm * (-0.5 * k.rho * cd * area * vn * std::fabs(vn));
    double depthC = (ha + hb + hc) / 3;
    double radC = s.radiationDamping * k.rho * std::sqrt(k.g * k.lengthRef) * std::exp(-depthC / (0.5 * k.lengthRef));
    Fd = Fd - nrm * (radC * area * vn);
    Vec3d vt = v - nrm * vn;
    double vtl = length(vt);
    if (vtl > 1e-6) {
        double re = std::max(length(v) * k.lengthRef / s.kinematicViscosity, 1e5);
        double l10 = std::log10(re) - 2;
        double cf = 0.075 / (l10 * l10);
        Fd = Fd + vt * (-0.5 * k.rho * cf * area * vtl);
    }
    acc.force = acc.force + Fd;
    acc.torque = acc.torque + cross(cen - k.com, Fd);
    if (partial && vn > s.splashSpeedThreshold) {
        double w = area * (vn - s.splashSpeedThreshold);
        acc.splashPos = acc.splashPos + cen * w;
        Vec3d sv = vt * 0.6 + Vec3d{0, 1, 0} * (vn * 0.8) + nrm * (vn * 0.4);
        acc.splashVel = acc.splashVel + sv * w;
        acc.splashWeight += w;
    }
}

inline Vec3d cut(const Vec3d& a, const Vec3d& b, double da, double db) { return a + (b - a) * (da / (da - db)); }

inline void clipTriangle(Vec3d p0, Vec3d p1, Vec3d p2, double d0, double d1, double d2, const Ctx& k, Partial& acc) {
    bool s0 = d0 < 0, s1 = d1 < 0, s2 = d2 < 0;
    int n = int(s0) + int(s1) + int(s2);
    if (n == 0) return;
    if (n == 3) { subTriangle(p0, p1, p2, -d0, -d1, -d2, k, false, acc); return; }
    Vec3d a = p0, b = p1, c = p2;
    double da = d0, db = d1, dc = d2;
    if (n == 1) {
        if (s1) { a = p1; b = p2; c = p0; da = d1; db = d2; dc = d0; }
        else if (s2) { a = p2; b = p0; c = p1; da = d2; db = d0; dc = d1; }
        Vec3d qab = cut(a, b, da, db), qac = cut(a, c, da, dc);
        subTriangle(a, qab, qac, -da, 0, 0, k, true, acc);
    } else {
        if (!s1) { a = p1; b = p2; c = p0; da = d1; db = d2; dc = d0; }
        else if (!s2) { a = p2; b = p0; c = p1; da = d2; db = d0; dc = d1; }
        Vec3d qab = cut(a, b, da, db), qca = cut(c, a, dc, da);
        subTriangle(qab, b, c, 0, -db, -dc, k, true, acc);
        subTriangle(qab, c, qca, 0, -dc, 0, k, true, acc);
    }
}
} // namespace

template <class Source>
HydroResult computeWith(const HullMesh& hull, const BodyState& state, double rho, double g, const HydroSettings& s, const Source& src,
                        const Vec3d& waterVelocity, HydroScratch* given) {
    HydroResult out;
    const std::size_t nv = hull.positions.size() / 3, nt = hull.indices.size() / 3;
    if (nv == 0 || nt == 0) return out;
    double orient = signedVolume(hull) < 0 ? -1.0 : 1.0;   // CAD meshes may be inside-out
    auto& jobs = jobs::JobSystem::shared();
    int chunks = int(nt) >= parallelTriangleThreshold ? std::max(1, std::min(64, int(nt) / 512)) : 1;   // fixed: independent of thread count
    HydroScratch local;
    HydroScratch& sc = given ? *given : local;
    if (sc.world.size() < nv) { sc.world.resize(std::max(nv, sc.world.size() * 2)); sc.dist.resize(sc.world.size()); }
    if (sc.partials.size() < std::size_t(chunks)) sc.partials.resize(std::size_t(std::max(chunks, 8)));
    Vec3d* W = sc.world.data();
    double* D = sc.dist.data();
    const float* P = hull.positions.data();
    auto vertexPass = [&](int a, int b) {
        for (int i = a; i < b; ++i) {
            Vec3d lp{P[i * 3], P[i * 3 + 1], P[i * 3 + 2]};
            Vec3d p = state.position + state.rotation.act(lp);
            W[i] = p;
            D[i] = p.y - src.height(p.x, p.z);
        }
    };
    if (int(nv) >= parallelVertexThreshold) jobs.parallelFor(int(nv), 512, vertexPass, "water.hull.verts");
    else vertexPass(0, int(nv));
    Vec3d bmin{INFINITY, INFINITY, INFINITY}, bmax{-INFINITY, -INFINITY, -INFINITY};
    bool anySub = false;
    for (std::size_t i = 0; i < nv; ++i) { bmin = geo::vmin(bmin, W[i]); bmax = geo::vmax(bmax, W[i]); if (D[i] < 0) anySub = true; }
    if (!anySub) return out;
    Vec3d ext = bmax - bmin;
    Ctx k{rho, g, state.centerOfMass, &state, waterVelocity, std::max(std::max(ext.x, std::max(ext.y, ext.z)), 0.1), &s};
    const uint32_t* I = hull.indices.data();
    std::size_t per = (nt + std::size_t(chunks) - 1) / std::size_t(chunks);
    auto triPass = [&](int a, int b) {
        for (int ch = a; ch < b; ++ch) {
            Partial acc;
            std::size_t t0 = std::size_t(ch) * per, t1 = std::min(nt, t0 + per);
            for (std::size_t t = t0; t < t1; ++t) {
                uint32_t ia = I[t * 3], ib = I[t * 3 + 1], ic = I[t * 3 + 2];
                double da = D[ia], db = D[ib], dc = D[ic];
                if (da >= 0 && db >= 0 && dc >= 0) continue;
                if (orient > 0) clipTriangle(W[ia], W[ib], W[ic], da, db, dc, k, acc);
                else clipTriangle(W[ia], W[ic], W[ib], da, dc, db, k, acc);
            }
            sc.partials[std::size_t(ch)] = acc;
        }
    };
    if (chunks > 1) jobs.parallelFor(chunks, 1, triPass, "water.hull.tris");
    else triPass(0, 1);
    Partial total;
    for (int i = 0; i < chunks; ++i) {
        const Partial& p = sc.partials[std::size_t(i)];
        total.force = total.force + p.force; total.torque = total.torque + p.torque; total.volume += p.volume; total.wetted += p.wetted;
        total.splashPos = total.splashPos + p.splashPos; total.splashVel = total.splashVel + p.splashVel; total.splashWeight += p.splashWeight;
    }
    out.ft = {total.force, total.torque};
    out.volume = std::max(total.volume, 0.0);
    out.wetted = total.wetted;
    if (total.splashWeight > 1e-6) {
        out.splash = true; out.splashPos = total.splashPos / total.splashWeight; out.splashVel = total.splashVel / total.splashWeight;
        out.splashWeight = total.splashWeight;
    }
    return out;
}

namespace {
struct FnSource { const std::function<double(double, double)>* f; double height(double x, double z) const { return (*f)(x, z); } };
}

template HydroResult computeWith<OceanHeightSource>(const HullMesh&, const BodyState&, double, double, const HydroSettings&,
                                                    const OceanHeightSource&, const Vec3d&, HydroScratch*);

HydroResult compute(const HullMesh& hull, const BodyState& state, double rho, double g, const HydroSettings& s,
                    const std::function<double(double, double)>& heightAt, const Vec3d& waterVelocity, HydroScratch* scratch) {
    return computeWith(hull, state, rho, g, s, FnSource{&heightAt}, waterVelocity, scratch);
}

} // namespace hydro

// ---------------------------------------------------------------- splashes

void SplashSystem::emit(const Vec3d& position, const Vec3d& velocity, int count, double spread, double radius) {
    if (count <= 0) return;
    std::lock_guard<std::mutex> lk(mutex_);
    int room = maxParticles - int(particles_.size()) - int(pending_.size());
    int n = std::min(count, std::max(0, room));
    double sp = std::max(length(velocity), 1.0) * spread;
    for (int i = 0; i < n; ++i) {
        Vec3d j{rng_.unit() * 2 - 1, rng_.unit() * 2 - 1, rng_.unit() * 2 - 1};
        Vec3d o = Vec3d{rng_.unit() * 2 - 1, 0, rng_.unit() * 2 - 1} * radius;
        Vec3d v = velocity + j * sp + Vec3d{0, rng_.unit() * sp, 0};
        float life = float(0.6 + rng_.unit() * 1.4), size = float(0.05 + rng_.unit() * 0.18);
        pending_.push_back({position + o, v, 0, life, size});
    }
}

void SplashSystem::update(double dt, double gravity, const std::function<double(double, double)>& surface) {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        particles_.insert(particles_.end(), pending_.begin(), pending_.end());
        pending_.clear();
    }
    if (!(dt > 0) || particles_.empty()) return;
    std::size_t alive = 0;
    for (std::size_t i = 0; i < particles_.size(); ++i) {
        Particle p = particles_[i];
        double sp = length(p.vel);
        p.vel = p.vel + (Vec3d{0, -gravity, 0} - p.vel * (airDrag * sp)) * dt;
        p.pos = p.pos + p.vel * dt;
        p.age += float(dt);
        p.size *= float(1 + 0.6 * dt);
        bool below = p.vel.y < 0 && p.pos.y < surface(p.pos.x, p.pos.z);
        if (p.age < p.life && !below) particles_[alive++] = p;
    }
    particles_.resize(alive);
}

int SplashSystem::count() const { std::lock_guard<std::mutex> lk(mutex_); return int(particles_.size()); }

void SplashSystem::instances(const Vec3d& o, std::vector<float>& out) const {
    out.clear();
    out.reserve(particles_.size() * 8);
    for (const auto& p : particles_) {
        Vec3d r = p.pos - o;
        float fade = 1 - p.age / p.life;
        float v[8] = {float(r.x), float(r.y), float(r.z), p.size, 0.55f * fade, 0, 0, 0};
        out.insert(out.end(), v, v + 8);
    }
}

} // namespace pw::water
