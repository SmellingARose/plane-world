// Fast+ effects and equation capture (port of Sources/Physics/FastGaps.swift). Every effect is consulted only when
// CraftSim::slipstream is on and its toggle is set, so the slipstream-off trajectory is unaffected.
#include <cmath>
#include <limits>
#include "pw/sim/craft_sim.h"

namespace pw::sim {

CraftSim::PFactorLoads CraftSim::pFactorLoads(const Vec3d& dir, const Vec3d& rel, double T, double omega, double R, double rho,
                                             double axial, double vi) {
    PFactorLoads out;
    double ax = dot(rel, dir);
    Vec3d vc = rel - dir * ax;
    double vcs = length(vc);
    if (vcs < 1e-3 || std::fabs(omega) < 1e-6) return out;
    Vec3d ch = vc / vcs;
    out.vc = vcs;
    out.mu = vcs / (std::fabs(omega) * R);
    out.alphaDeg = std::atan2(vcs, smax(std::fabs(ax), 1e-9)) / kDeg;
    double e = smin(0.3 * R, 0.5 * out.mu * R);
    Vec3d wHat = omega >= 0 ? dir : -dir;
    Vec3d adv = cross(wHat, ch);
    out.offset = adv * e;
    out.normal = ch * (0.5 * rho * kPi * R * R * (smax(0, axial) + vi) * vcs);
    (void)T;
    return out;
}

void CraftSim::applyBlockage(const Quatd& q, const Vec3d& origin, EquationCapture* cap) {
    const int np = int(parts_.size());
    const SimPart* P = parts_.data();
    for (int k = 0; k < wakeCount_; ++k) {
        RotorWake w = wakeBuf_[std::size_t(k)];
        double R = w.radius;
        w.nBlk = 0;
        for (int j = 0; j < np; ++j) {
            if (!P[j].isBlocker) continue;
            Quatd qp = q * P[j].effQ;
            Vec3d c = origin + q.act(P[j].basePos + P[j].effQ.act(P[j].ctr));
            Vec3d d = c - w.center;
            double s = dot(d, w.axis);
            if (s <= 0.1 * R || s > aero::kWakeMixingRadii * 4 * R) continue;
            double lat = length(d - w.axis * s);
            if (lat > R) continue;
            Vec3d a = qp.inverse().act(w.axis), sz = P[j].size;
            double A = std::fabs(a.x) * sz.y * sz.z + std::fabs(a.y) * sz.x * sz.z + std::fabs(a.z) * sz.x * sz.y;
            if (A < 1e-6) continue;
            double rb = std::sqrt(A / kPi);
            double len = 0.5 * (std::fabs(a.x) * sz.x + std::fabs(a.y) * sz.y + std::fabs(a.z) * sz.z);
            int slot = w.nBlk;
            if (slot == kMaxBlockers) { if (s >= w.blkS[slot - 1]) continue; slot -= 1; }
            else w.nBlk += 1;
            while (slot > 0 && w.blkS[slot - 1] > s) {
                w.blkS[slot] = w.blkS[slot - 1]; w.blkR[slot] = w.blkR[slot - 1]; w.blkLen[slot] = w.blkLen[slot - 1];
                w.blkX[slot] = w.blkX[slot - 1]; w.blkY[slot] = w.blkY[slot - 1]; w.blkZ[slot] = w.blkZ[slot - 1];
                slot -= 1;
            }
            w.blkS[slot] = s; w.blkR[slot] = rb; w.blkLen[slot] = len; w.blkX[slot] = c.x; w.blkY[slot] = c.y; w.blkZ[slot] = c.z;
            if (cap) {
                EquationRecord r; r.id = EquationID::Blockage; r.partIndex = j;
                r.set(0, s); r.set(1, rb); r.set(2, A); r.set(3, R); r.set(4, 1 - RotorWake::blockDepth);
                cap->append(r);
            }
        }
        wakeBuf_[std::size_t(k)] = w;
    }
    // Coaxial swirl recovery (one level: the nearest downstream rotor inside the wake core).
    for (int k = 0; k < wakeCount_; ++k) {
        const RotorWake wk = wakeBuf_[std::size_t(k)];
        int best = -1;
        double bestS = std::numeric_limits<double>::infinity();
        for (int j = 0; j < wakeCount_; ++j) {
            if (j == k) continue;
            Vec3d d = wakeBuf_[std::size_t(j)].center - wk.center;
            double s = dot(d, wk.axis);
            if (s <= 0 || s > aero::kWakeMixingRadii * 4 * wk.radius) continue;
            if (length(d - wk.axis * s) > wk.radius || dot(wakeBuf_[std::size_t(j)].axis, wk.axis) < 0.8) continue;
            if (s < bestS) { bestS = s; best = j; }
        }
        if (best >= 0) { wakeBuf_[std::size_t(k)].swirlEnd = bestS; wakeBuf_[std::size_t(best)].swirl += wk.swirl0; }
    }
}

void CraftSim::buildHorseshoes(const Quatd& q, const Vec3d& origin, double rho) {
    int n = 0;
    for (int g = 0; g < int(wingGroups_.size()); ++g) {
        const WingGroup& G = wingGroups_[std::size_t(g)];
        const WingGroupState& st = groupState_[std::size_t(g)];
        double Lm = length(st.lift), Vm = length(st.air);
        if (Vm < 1 || Lm < 1e-6 || rho < 1e-6) continue;
        Vec3d ax = q.act(G.axis), Lh = st.lift / Lm, Vh = st.air / Vm;
        Vec3d gh = cross(Lh, Vh);
        double al = dot(ax, gh);
        if (std::fabs(al) < 0.3) continue;
        double bp = kPi / 4 * G.span;
        Vec3d c = origin + q.act(G.center);
        Vec3d half = ax * ((al >= 0 ? 0.5 : -0.5) * bp);
        double rc = smax(0.05 * bp, 0.3 * G.chord);
        Horseshoe hs;
        hs.a = c - half; hs.b = c + half; hs.u = Vh; hs.gamma = Lm / (rho * Vm * bp); hs.rc2 = rc * rc; hs.group = g; hs.chord = G.chord;
        horseshoes_[std::size_t(n++)] = hs;
    }
    horseshoeCount_ = n;
}

Vec3d CraftSim::gyroTorque(const Quatd& q, const Vec3d& wW, EquationCapture* cap) {
    Vec3d T;
    const int np = int(parts_.size());
    const SimPart* P = parts_.data();
    for (int i = 0; i < np; ++i) {
        if (!(P[i].kIrot > 0 && P[i].omega != 0)) continue;
        Vec3d hv;
        if (P[i].is(PartType::Prop)) hv = q.act(P[i].effQ.act({1, 0, 0})) * (P[i].kIrot * P[i].omega);
        else if (P[i].is(PartType::Wheel)) hv = q.act(P[i].effQ.act({0, 0, 1})) * (-P[i].kIrot * P[i].omega);
        else continue;
        Vec3d tq = -cross(wW, hv);
        T += tq;
        if (cap) {
            EquationRecord r; r.id = EquationID::Gyroscopic; r.partIndex = i;
            r.set(0, P[i].kIrot); r.set(1, std::fabs(P[i].omega)); r.set(2, length(wW)); r.set(3, length(hv)); r.set(4, length(tq));
            r.result = {{}, tq};
            cap->append(r);
        }
    }
    return T;
}

void CraftSim::captureBodyDrag(int i, double rho, double sp, double cd, double A, const Vec3d& v, const Vec3d& pw, EquationCapture& cap) {
    EquationRecord r; r.id = EquationID::BodyDrag; r.partIndex = i;
    r.set(0, rho); r.set(1, sp); r.set(2, cd); r.set(3, A); r.set(4, 0.5 * rho * sp * sp * cd * A);
    Vec3d f = v * (-0.5 * rho * sp * cd * A);
    r.result = {f, cross(pw - position_, f)};
    cap.append(r);
}

void CraftSim::capturePFactor(int i, const PFactorLoads& pf, const Vec3d& dir, const Vec3d& pw, double Tn, EquationCapture& cap) {
    const SimPart& p = parts_[std::size_t(i)];
    EquationRecord rec; rec.id = EquationID::PFactor; rec.partIndex = i;
    rec.set(0, pf.alphaDeg); rec.set(1, pf.vc); rec.set(2, std::fabs(p.omega)); rec.set(3, smax(0.05, p.kD / 2)); rec.set(4, pf.mu);
    rec.set(5, length(pf.offset)); rec.set(6, Tn); rec.set(7, length(pf.normal));
    Vec3d mom = cross(pf.offset, dir * Tn);
    rec.set(8, length(mom));
    rec.result = {pf.normal, mom + cross(pw - position_, pf.normal)};
    cap.append(rec);
}

void CraftSim::accumulateGroupLift(int ns, const Quatd& q, const Vec3d& origin, const Vec3d& windHere, const Vec3d& velocity, const Vec3d& wW) {
    int ng = int(wingGroups_.size());
    for (int g = 0; g < ng; ++g) groupState_[std::size_t(g)].accLift = {};
    for (int si = 0; si < ns; ++si) {
        int g = parts_[std::size_t(strips_[std::size_t(si)].part)].wingGroup;
        if (g >= 0) groupState_[std::size_t(g)].accLift += stripBuf_[std::size_t(si)].lift;
    }
    for (int g = 0; g < ng; ++g) {
        Vec3d cw = origin + q.act(wingGroups_[std::size_t(g)].center);
        groupState_[std::size_t(g)].lift = groupState_[std::size_t(g)].accLift;
        groupState_[std::size_t(g)].air = windHere + wakeView_.velocity(cw) - (velocity + cross(wW, cw - position_));
    }
}

void CraftSim::captureStrips(int ns, double rho, double sos, EquationCapture& cap) {
    for (int si = 0; si < ns; ++si) {
        const StripResult& r = stripBuf_[std::size_t(si)];
        int pi = strips_[std::size_t(si)].part;
        if (r.speed < 0.3) continue;
        const aero::WingConst& k = parts_[std::size_t(pi)].wing;
        const aero::WingParams& p = k.params;
        double area = strips_[std::size_t(si)].area;
        double M = smin(r.speed / sos, 0.8), beta = std::sqrt(1 - M * M);
        double slope = aero::liftSlope(p.aspectRatio, r.speed / sos) * r.gain;
        double cl0 = p.camberCl0 / beta, dcl = 0.0;
        if (p.flapChordFraction > 0 && r.flap != 0) {
            double eff = 0.75 - 0.25 * smoothstep(15 * kDeg, 40 * kDeg, std::fabs(r.flap));
            dcl = slope * k.flapTau * eff * r.flap; cl0 += dcl;
            EquationRecord f; f.id = EquationID::FlapIncrement; f.partIndex = pi;
            f.set(0, k.flapTau); f.set(1, eff); f.set(2, r.flap / kDeg); f.set(3, slope); f.set(4, dcl);
            cap.append(f);
        }
        double qS = 0.5 * rho * r.speed * r.speed * area;
        const ForceTorque& ft = r.ft;
        EquationRecord l; l.id = EquationID::WingLift; l.partIndex = pi;
        l.set(0, slope); l.set(1, r.alpha / kDeg); l.set(2, -cl0 / slope / kDeg); l.set(3, rho); l.set(4, r.speed); l.set(5, area);
        l.set(6, r.cl); l.set(7, r.cl * qS);
        l.result = {r.lift, {}};
        cap.append(l);
        EquationRecord d; d.id = EquationID::WingDrag; d.partIndex = pi;
        double cf = 0.455 / std::pow(std::log10(smax(r.re, 1e4)), 2.58), cd0 = 2 * cf * k.thickFactor;
        d.set(0, rho); d.set(1, r.speed); d.set(2, area); d.set(3, cd0); d.set(4, r.cl); d.set(5, p.aspectRatio); d.set(6, 0.8);
        d.set(7, r.phi); d.set(8, r.cd); d.set(9, r.cd * qS);
        d.result = {ft.force - r.lift, {}};
        cap.append(d);
        EquationRecord m; m.id = EquationID::WingMoment; m.partIndex = pi;
        m.set(0, r.cp); m.set(1, parts_[std::size_t(pi)].kChord); m.set(2, r.ch); m.set(3, r.hinge);
        m.result = ft;
        cap.append(m);
        double stall = (11 + 5 * smoothstep(5, 7, std::log10(smax(r.re, 1e3))) - k.stallThick) * kDeg;
        double aZL = r.alpha + cl0 / slope;
        if (r.stalled || std::fabs(aZL) > 0.8 * stall) {
            EquationRecord s; s.id = EquationID::Stall; s.partIndex = pi;
            s.set(0, aZL / kDeg); s.set(1, stall / kDeg); s.set(2, r.re); s.set(3, (std::fabs(aZL) - stall) / kDeg); s.set(4, r.cl);
            cap.append(s);
        }
        if (dwView_.count > 0) {
            int grp = parts_[std::size_t(pi)].wingGroup;
            Vec3d v = dwView_.velocity(r.pac, grp);
            Vec3d lh = length(r.lift) > 1e-9 ? r.lift / length(r.lift) : Vec3d{0, 1, 0};
            double wv = -dot(v, lh);
            EquationRecord e; e.id = EquationID::Downwash; e.partIndex = pi;
            double gam = 0, bp = 0;
            for (int hh = 0; hh < dwView_.count; ++hh) {
                const Horseshoe& H = dwView_.buf[hh];
                if (H.group == grp) continue;
                gam = smax(gam, H.gamma); bp = smax(bp, length(H.b - H.a));
            }
            e.set(0, gam); e.set(1, bp); e.set(2, wv); e.set(3, r.speed); e.set(4, std::atan2(wv, r.speed) / kDeg);
            cap.append(e);
        }
    }
}

void CraftSim::captureProp(int i, const Vec3d& dir, const Vec3d& pw, double P0, double vax, double Tn, double dEff, double targetOmega,
                           double rho, bool slip, double groundH, const Vec3d& inflow, EquationCapture& cap) {
    const SimPart& p = parts_[std::size_t(i)];
    double R = smax(0.05, p.kD / 2), A = kPi * dEff * dEff / 4;
    Vec3d f = dir * Tn;
    ForceTorque ft{f, cross(pw - position_, f)};
    double vi = slip ? p.vi : aero::diskVelocity(smax(Tn, 0), rho, A, vax, false);
    EquationRecord m; m.id = EquationID::PropMomentum; m.partIndex = i;
    m.set(0, 0.75); m.set(1, P0); m.set(2, vax); m.set(3, vi); m.set(4, rho); m.set(5, A); m.set(6, Tn); m.result = ft;
    cap.append(m);
    EquationRecord t; t.id = EquationID::PropTorque; t.partIndex = i;
    double Q = std::fabs(targetOmega) > 1 ? P0 * 0.75 / std::fabs(targetOmega) : 0;
    t.set(0, 0.75); t.set(1, P0); t.set(2, std::fabs(targetOmega)); t.set(3, slip ? Q : 0.25 * Q);
    t.result = {{}, -dir * ((slip ? Q : 0.25 * Q) * (p.omega >= 0 ? 1 : -1))};
    cap.append(t);
    if (!slip) return;
    if (p.kDucted) {
        EquationRecord d; d.id = EquationID::DuctThrust; d.partIndex = i;
        d.set(0, 1); d.set(1, p.kD); d.set(2, dEff); d.set(3, Tn);
        cap.append(d);
    }
    EquationRecord g; g.id = EquationID::RotorGroundEffect; g.partIndex = i;
    g.set(0, groundH); g.set(1, R); g.set(2, smax(groundH, 0.5 * R) / R); g.set(3, dir.y);
    g.set(4, aero::rotorGroundEffectGain(groundH, R, dir.y));
    cap.append(g);
    EquationRecord s; s.id = EquationID::SlipstreamVelocity; s.partIndex = i;
    s.set(0, p.vi); s.set(1, R); s.set(2, p.kDucted ? p.vi : 2 * p.vi); s.set(3, length(inflow));
    cap.append(s);
}

void CraftSim::capturePanels(int i, const ForceTorque& ft, double rho, double nu, double sos, EquationCapture& cap) {
    int slot = parts_[std::size_t(i)].meshSlot;
    const PanelMesh& m = *meshes_[std::size_t(batchMesh_[std::size_t(slot)])];
    PanelBreakdown b = m.breakdown(slotQ_[std::size_t(slot)], slotO_[std::size_t(slot)], pbCom_, pbLin_, pbAng_, pbWind_,
                                   pbWashOn_ ? &pbWash_ : nullptr, rho, nu, sos);
    EquationRecord n; n.id = EquationID::PanelNewtonian; n.partIndex = i;
    n.set(0, double(b.panels)); n.set(1, double(b.windward)); n.set(2, double(b.shadowedWindward)); n.set(3, b.maxQ); n.set(4, length(b.pressure));
    n.result = {b.pressure, {}};
    cap.append(n);
    EquationRecord f; f.id = EquationID::PanelFriction; f.partIndex = i;
    f.set(0, b.meanRe); f.set(1, b.meanCf); f.set(2, length(b.friction));
    f.result = {b.friction, {}};
    cap.append(f);
    if (pbWashOn_) {
        EquationRecord w; w.id = EquationID::CadWash; w.partIndex = i;
        w.set(0, double(b.panels)); w.set(1, b.washMean); w.set(2, b.washMax); w.result = ft;
        cap.append(w);
    }
}

} // namespace pw::sim
