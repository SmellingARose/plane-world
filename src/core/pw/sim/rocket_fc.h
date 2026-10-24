#pragma once
// Built-in rocket flight controller (FLY): attitude hold with a gimballed liquid engine (PartType::Rocket).
// Angle mode like MultirotorFC: the pitch / yaw sticks command a tilt of the rocket's long axis (released = hold
// vertical), throttle passes straight through. The gimbal-to-torque mapping is measured from where the engine sits
// relative to the centre of mass and how it is mounted, so any single-engine layout works.
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
    double maxTiltDeg = 20, kp = 2.5, ki = 0.5, kd = 1.2;
private:
    int throttle_ = -1, gPitch_ = -1, gYaw_ = -1;
    double inv_[2][2] = {{0, 0}, {0, 0}};   // gimbal command (pitch, yaw) per unit normalised body torque (z, x)
    double iPitch_ = 0, iRoll_ = 0;
};

} // namespace pw::sim
