// Port of Sources/Physics/FullAero.swift (CraftSim side of AeroModel::Full) and Sources/Craft/AeroGeometry.swift.
#include "pw/sim/full_aero.h"
#include <algorithm>
#include <cmath>
#include "pw/craft/document.h"
#include "pw/craft/mesh.h"
#include "pw/sim/craft_sim.h"

namespace pw::sim {

const char* toString(AeroModel m) { return m == AeroModel::Full ? "full" : "fast"; }

std::vector<AeroPartGeometry> aeroParts(const craft::CraftDocument& craft) {
    std::vector<AeroPartGeometry> out;
    out.reserve(craft.parts.size());
    for (std::size_t i = 0; i < craft.parts.size(); ++i) {
        const craft::CraftPart& p = craft.parts[i];
        craft::MeshData m = craft::partMesh(p);
        AeroPartGeometry g;
        g.partIndex = int(i); g.kind = p.type; g.isRotor = p.type == "prop";
        g.positions.reserve(m.positions.size());
        for (const auto& v : m.positions) g.positions.push_back({v.x, v.y, v.z});
        g.indices = std::move(m.indices);
        out.push_back(std::move(g));
    }
    return out;
}

bool CraftSim::enableFull(AeroBackend& backend, const craft::CraftDocument& craft, const CFDSettings& settings, std::string* err) {
    if (!loaded_) { if (err) *err = "CFD unavailable: no craft loaded"; return false; }
    if (!backend.isAvailable()) { if (err) *err = "CFD unavailable: backend reports isAvailable = false"; return false; }
    if (!backend.configure(aeroParts(craft), settings, err)) return false;
    aeroBackend = &backend;
    aeroModel = AeroModel::Full;
    return true;
}

std::optional<ForceTorque> CraftSim::cfdForce(int i) const {
    if (!full_ || !(fullActive_ || aeroModel == AeroModel::Full) || i < 0 || i >= full_->count) return std::nullopt;
    return full_->forces[std::size_t(i)];
}

bool CraftSim::prepareFull() {
    if (!aeroBackend || !aeroBackend->isAvailable()) return false;
    if (full_ && full_->count == int(parts_.size()) && full_->backend == aeroBackend) return true;
    full_ = std::make_unique<FullAeroBuffers>(int(parts_.size()));
    full_->backend = aeroBackend;
    return true;
}

void CraftSim::resetFull() {
    if (!full_) return;
    FullAeroBuffers& f = *full_;
    if (f.pending && aeroBackend) aeroBackend->collect(f.forces.data(), f.sample.data(), f.count);
    f.pending = false; f.counter = 0; f.collected = 0;
    for (auto& x : f.forces) x = ForceTorque{};
    if (aeroBackend) aeroBackend->reset();
}

void CraftSim::fullCollect() {
    if (!full_ || !aeroBackend) return;
    FullAeroBuffers& f = *full_;
    if (equationCapture && equationCapture->requested) for (auto& x : f.fast) x = ForceTorque{};
    const int every = std::max(1, aeroBackend->settings().updateEvery);
    if (!f.pending || f.counter % every != 0) return;
    if (aeroBackend->collect(f.forces.data(), f.sample.data(), f.count)) f.collected += 1;
    f.pending = false;
}

void CraftSim::fullSubmit(double h, const SimEnvironment& env) {
    if (!full_ || !aeroBackend) return;
    FullAeroBuffers& f = *full_;
    const int every = std::max(1, aeroBackend->settings().updateEvery);
    f.counter += 1;
    if (f.counter % every != 0 || f.pending) return;
    const Quatd q = orientation_;
    const Vec3d origin = position_ - q.act(comLocal_), wW = omegaWorld(q);
    int nr = 0;
    const int n = std::min(f.count, int(parts_.size()));
    for (int i = 0; i < n; ++i) {
        const SimPart& p = parts_[std::size_t(i)];
        Quatd rq = q * p.effQ;
        if (p.is(PartType::Wheel)) rq = rq * Quatd::angleAxis(-p.spinAngle, {0, 0, 1});
        const Vec3d pw = origin + q.act(p.basePos);
        AeroPartPose pose;
        pose.position = pw; pose.rotation = rq.normalized();
        pose.linVel = velocity_ + cross(wW, pw - position_); pose.angVel = wW;
        f.poses[std::size_t(i)] = pose;
        if (p.is(PartType::Prop) && p.thrustNow > 0) {
            AeroRotorSource r;
            r.partIndex = i; r.center = pw; r.axis = q.act(p.effQ.act({1, 0, 0}));
            r.radius = std::max(0.05, p.kD / 2); r.thrust = p.thrustNow; r.torque = p.wakeQ; r.omega = p.omega;
            f.rotors[std::size_t(nr++)] = r;
        }
    }
    f.rotorCount = nr;
    const Atmosphere atm = env.atmosphere(position_.y);
    AeroEnvironmentSample e;
    e.rho = atm.density; e.nu = aero::viscosity(atm.temperature) / std::max(atm.density, 1e-9);
    e.speedOfSound = atm.speedOfSound;
    const double gh = groundHeight(env, position_.x, position_.z);
    e.wind = WindField(env.wind, 0).velocity(position_, position_.y - gh, env.time);
    e.groundHeight = groundEnabled ? gh : -std::numeric_limits<double>::infinity();
    aeroBackend->submit(position_, velocity_, q, f.poses.data(), f.count, f.rotors.data(), nr, e, h * double(every));
    f.pending = true;
}

void CraftSim::fullFastBreakdown(int np, int ns) {
    if (!full_) return;
    FullAeroBuffers& f = *full_;
    for (int si = 0; si < ns; ++si) {
        const int k = strips_[std::size_t(si)].part;
        f.fast[std::size_t(k)] = f.fast[std::size_t(k)] + stripBuf_[std::size_t(si)].ft;
    }
    for (int i = 0; i < np; ++i) {
        const SimPart& p = parts_[std::size_t(i)];
        if (!p.isBody || p.meshSlot < 0) continue;
        ForceTorque ft;
        for (int k = p.itemStart; k < p.itemStart + p.itemCount; ++k) ft = ft + itemOut_[std::size_t(k)];
        f.fast[std::size_t(i)] = ft;
    }
}

void CraftSim::fullCaptureRecords(int np, EquationCapture& cap) {
    if (!full_) return;
    const FullAeroBuffers& f = *full_;
    for (int i = 0; i < std::min(np, f.count); ++i) {
        if (parts_[std::size_t(i)].is(PartType::Prop)) continue;
        const ForceTorque a = f.fast[std::size_t(i)], c = f.forces[std::size_t(i)];
        const double fa = length(a.force), fc = length(c.force);
        if (fa < 1e-9 && fc < 1e-9) continue;
        EquationRecord r;
        r.id = EquationID::CfdMomentumExchange; r.partIndex = i;
        r.set(0, a.force.x); r.set(1, a.force.y); r.set(2, a.force.z);
        r.set(3, a.torque.x); r.set(4, a.torque.y); r.set(5, a.torque.z);
        r.set(6, fa); r.set(7, fc); r.set(8, fa > 1e-9 ? (fc - fa) / fa * 100 : 0);
        r.result = c;
        cap.append(r);
    }
}

} // namespace pw::sim
