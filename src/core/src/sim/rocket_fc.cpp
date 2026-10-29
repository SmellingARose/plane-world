#include "pw/sim/rocket_fc.h"
#include <algorithm>
#include <cmath>

namespace pw::sim {

bool RocketFC::attach(const CraftSim& sim) {
    engine_ = throttle_ = gPitch_ = gYaw_ = -1;
    const auto& parts = sim.parts();
    const auto poses = sim.partPoses();
    for (std::size_t i = 0; i < parts.size(); ++i) {
        const SimPart& p = parts[i];
        if (!p.is(PartType::Rocket)) continue;
        const std::string& id = poses[i].partID;
        throttle_ = sim.outputIndex(id); gPitch_ = sim.outputIndex(id + ".gimbal-pitch"); gYaw_ = sim.outputIndex(id + ".gimbal-yaw");
        if (throttle_ < 0 || gPitch_ < 0 || gYaw_ < 0) { throttle_ = -1; continue; }
        // Body-frame torque per unit thrust at full deflection of each gimbal axis (same rotation as the sim's engine;
        // the thrust line passes through the gimbal pivot).
        const Vec3d r = p.basePos + p.baseQN.act({p.kPivot, 0, 0}) - sim.comLocal();
        auto torque = [&](double pitch, double yaw) {
            const Quatd g = Quatd::angleAxis(yaw, {0, 1, 0}) * Quatd::angleAxis(pitch, {0, 0, 1});
            return cross(r, p.baseQN.act(g.act({1, 0, 0})));
        };
        const Vec3d t0 = torque(0, 0), tp = torque(p.kGimbal, 0) - t0, ty = torque(0, p.kGimbal) - t0;
        // M maps (pitch, yaw) command to (torque z, torque x); invert it (normalised so a unit torque request ~ full deflection)
        double m[2][2] = {{tp.z, ty.z}, {tp.x, ty.x}};
        const double scale = std::max({std::abs(m[0][0]), std::abs(m[0][1]), std::abs(m[1][0]), std::abs(m[1][1]), 1e-9});
        for (auto& row : m) for (double& v : row) v /= scale;
        const double det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        if (std::abs(det) < 1e-6) { throttle_ = -1; continue; }   // gimbal cannot steer (engine at the CoM?)
        engine_ = int(i); torquePerN_ = scale;
        inv_[0][0] = m[1][1] / det; inv_[0][1] = -m[0][1] / det; inv_[1][0] = -m[1][0] / det; inv_[1][1] = m[0][0] / det;
        reset();
        return true;
    }
    return false;
}

void RocketFC::update(CraftSim& sim, const RocketSticks& s, double dt) {
    if (throttle_ < 0 || dt <= 0) return;
    sim.setOutput(throttle_, std::clamp(s.throttle, 0.0, 1.0));
    const Quatd inv = sim.orientation().conjugate();
    const Vec3d up = inv.act({0, 1, 0}), w = inv.act(sim.angularVelocityWorld());   // body axes: +y along the rocket
    // Same conventions as MultirotorFC: tilting forward tips world-up towards body -x, tilting right towards -z.
    const double tilt = std::sin(maxTiltDeg * kDeg);
    // the wanted up vector (body x, z); brake > 0 leans it against the horizontal velocity as well
    double wx = -std::clamp(s.pitch, -1.0, 1.0) * tilt, wz = -std::clamp(s.yaw, -1.0, 1.0) * tilt;
    if (brake > 0) {
        const Vec3d v = sim.velocity(), vb = inv.act(Vec3d{v.x, 0, v.z});
        wx = std::clamp(wx + brake * vb.x, -tilt, tilt); wz = std::clamp(wz + brake * vb.z, -tilt, tilt);
    }
    const double ex = up.x - wx, ez = up.z - wz;
    if (sim.groundContact()) iPitch_ = iRoll_ = 0;
    iPitch_ = std::clamp(iPitch_ + ex * dt, -0.3, 0.3); iRoll_ = std::clamp(iRoll_ + ez * dt, -0.3, 0.3);
    // wanted angular acceleration (rad/s^2) about body +z (nose up) and +x (right side down)
    const double azW = -wn * wn * (ex + ki * iPitch_) - 2 * zeta * wn * w.z;
    const double axW = wn * wn * (ez + ki * iRoll_) - 2 * zeta * wn * w.x;
    // -> body torque -> normalised by what full gimbal deflection gives at the current thrust (spool-up: assume 30 %)
    const SimPart& e = sim.parts()[std::size_t(engine_)];
    const double authority = torquePerN_ * std::max(e.thrustNow, 0.3 * e.kThrust);
    const Mat3d& I = sim.inertia();
    const double tz = I.c[2].z * azW / authority, tx = I.c[0].x * axW / authority;
    sim.setOutput(gPitch_, std::clamp(inv_[0][0] * tz + inv_[0][1] * tx, -1.0, 1.0));
    sim.setOutput(gYaw_, std::clamp(inv_[1][0] * tz + inv_[1][1] * tx, -1.0, 1.0));
}

void RocketFC::updateClimb(CraftSim& sim, double climb, double pitch, double yaw, double dt) {
    if (throttle_ < 0 || dt <= 0) return;
    climb = std::clamp(climb, -1.0, 1.0);
    double throttle = 0;
    if (!(sim.groundContact() && climb <= 0)) {
        // Climb-rate loop around the hover throttle, tilt compensated. Thrust is about linear in throttle, so a
        // throttle step of hover_ is about 1 g: gains scaled by hover_ give the same response (~1 m/s² per m/s of
        // climb-rate error, the hover estimate following at 0.3 m/s² per m/s·s) on any vehicle.
        const Vec3d up = sim.orientation().conjugate().act({0, 1, 0});
        const double err = climb * maxClimb - sim.velocity().y;
        hover_ = std::clamp(hover_ + 0.03 * hover_ * err * dt, 0.02, 1.0);
        throttle = std::clamp((hover_ + 0.1 * hover_ * err) / std::max(0.5, up.y), 0.0, 1.0);
    }
    update(sim, RocketSticks{throttle, pitch, yaw}, dt);
}

} // namespace pw::sim
