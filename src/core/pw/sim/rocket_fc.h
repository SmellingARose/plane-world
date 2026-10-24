#pragma once
// Built-in rocket flight controller (FLY): attitude hold with a gimballed liquid engine (PartType::Rocket).
// Angle mode like MultirotorFC: the pitch / yaw sticks command a tilt of the rocket's long axis (released = hold
// vertical), throttle passes straight through. The gimbal-to-torque mapping is measured from where the engine's gimbal
// pivot sits relative to the centre of mass and how it is mounted, so any single-engine layout works. The loop asks
// for an angular acceleration (natural frequency wn, damping zeta, plus a little integral) and turns it into a gimbal
// command with the vehicle's inertia and the engine's current thrust, so a 2 t hopper and a 35 t booster fly alike.
#include <vector>
#include "pw/sim/craft_sim.h"

namespace pw::sim {

struct RocketSticks { double throttle = 0, pitch = 0, yaw = 0; };   // throttle 0..1; pitch +1 = tilt forward (+x), yaw +1 = tilt right (+z)

class RocketFC {
public:
    /// Find the first rocket engine and its throttle / gimbal outputs. False if the craft has none.
    bool attach(const CraftSim& sim);
    void reset() { iPitch_ = iRoll_ = 0; }
    void update(CraftSim& sim, const RocketSticks& s, double dt);
    std::vector<int> outputs() const { return {throttle_, gPitch_, gYaw_}; }
    double maxTiltDeg = 20, wn = 1.2, zeta = 0.9, ki = 0.25;
private:
    int engine_ = -1, throttle_ = -1, gPitch_ = -1, gYaw_ = -1;
    double torquePerN_ = 0;                 // body torque per newton of thrust at full deflection (largest axis)
    double inv_[2][2] = {{0, 0}, {0, 0}};   // gimbal command (pitch, yaw) per unit normalised body torque (z, x)
    double iPitch_ = 0, iRoll_ = 0;
};

} // namespace pw::sim
