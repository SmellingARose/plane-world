#include "pw/sim/multirotor.h"
#include <algorithm>
#include <cmath>

namespace pw::sim {

bool MultirotorFC::attach(const CraftSim& sim) {
    rotors_.clear();
    const auto& parts = sim.parts();
    const auto poses = sim.partPoses();
    const Quatd inv = sim.orientation().conjugate();
    for (std::size_t i = 0; i < parts.size(); ++i) {
        const auto& p = parts[i];
        if (!p.is(PartType::Prop) || p.motor < 0) continue;
        const int out = sim.outputIndex(poses[std::size_t(p.motor)].partID);
        if (out < 0) continue;
        const Vec3d r = inv.act(poses[i].position - sim.position());   // body frame, from the CoM
        rotors_.push_back({out, r.x, r.z, p.kSpin});
    }
    if (rotors_.size() < 3) { rotors_.clear(); return false; }
    // normalise arm lengths so gains are layout independent
    double mx = 1e-6, mz = 1e-6;
    for (auto& r : rotors_) { mx = std::max(mx, std::abs(r.x)); mz = std::max(mz, std::abs(r.z)); }
    for (auto& r : rotors_) { r.x /= mx; r.z /= mz; }
    reset();
    return true;
}

void MultirotorFC::update(CraftSim& sim, const MultirotorSticks& s, double dt) {
    if (rotors_.empty() || dt <= 0) return;
    // Landed and no climb command: motors idle and the loops stay reset, so it sits still until you throttle up.
    if (sim.groundContact() && s.climb <= 0) {
        pitchI_ = rollI_ = 0;
        for (const auto& r : rotors_) sim.setOutput(r.output, 0);
        return;
    }
    const Quatd inv = sim.orientation().conjugate();
    const Vec3d up = inv.act({0, 1, 0});                    // world up in body axes (x fwd, y up, z right)
    const Vec3d w = inv.act(sim.angularVelocityWorld());    // body rates
    const double tilt = std::sin(maxTiltDeg * kDeg);
    // attitude: drive the body-frame up vector to the stick target.
    // Nose down tips world-up towards body -x, right side down tips it towards -z. Body rates: +w.z = nose up, +w.x = right side down.
    const double tx = -std::clamp(s.pitch, -1.0, 1.0) * tilt, tz = -std::clamp(s.roll, -1.0, 1.0) * tilt;
    const double ex = up.x - tx, ez = up.z - tz;
    pitchI_ = std::clamp(pitchI_ + ex * dt, -0.5, 0.5); rollI_ = std::clamp(rollI_ + ez * dt, -0.5, 0.5);   // trims CoM / thrust offsets
    const double uPitch = -kp * ex - ki * pitchI_ - kd * w.z;   // > 0 raises the nose (more thrust on +x rotors)
    const double uRoll = -kp * ez - ki * rollI_ + kd * w.x;     // > 0 raises the right side (more thrust on +z rotors)
    const double uYaw = std::clamp(0.25 * (-std::clamp(s.yaw, -1.0, 1.0) * maxYawRate - w.y), -0.2, 0.2);   // yaw +1 = turn right (negative rate about up)
    // Everything below is in THRUST fractions (0..1 of a rotor's static thrust); the output is converted to throttle
    // at the end. Static prop thrust grows as throttle^(2/3) (momentum theory, aero::propThrust), so throttle =
    // thrust^1.5 — mixing in thrust keeps the torque per unit delta the same at any throttle.
    // Climb-rate loop with a hover-thrust integrator, tilt compensated.
    const double vs = sim.velocity().y, vsErr = std::clamp(s.climb, -1.0, 1.0) * maxClimb - vs;
    hover_ = std::clamp(hover_ + vsErr * 0.05 * dt, 0.02, 0.95);
    const double thrust = std::clamp((hover_ + 0.04 * vsErr) / std::max(0.5, up.y), 0.0, 1.0);
    // Per-rotor attitude deltas (a rotor's drag torque yaws the body against its spin, so speeding up spin +1 rotors
    // yaws the body -y). Gains are tuned for a craft hovering at 30 % thrust and scale with the learned hover point.
    // "Air mode": shift the collective so the deltas fit in 0..1 rather than clipping them.
    const double g = std::max(0.1, hover_ / 0.3);
    auto delta = [&](const Rotor& r) { return g * (uPitch * r.x + uRoll * r.z - uYaw * r.spin); };
    double lo = 0, hi = 0;
    for (const auto& r : rotors_) { const double d = delta(r); lo = std::min(lo, d); hi = std::max(hi, d); }
    const double c = std::clamp(thrust, -lo, std::max(-lo, 1 - hi));
    for (const auto& r : rotors_) sim.setOutput(r.output, std::pow(std::clamp(c + delta(r), 0.0, 1.0), 1.5));
}

} // namespace pw::sim
