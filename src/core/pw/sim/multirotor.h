#pragma once
// Built-in multirotor flight controller (FLY): pilot sticks -> per-motor throttles.
// Angle mode: the pitch/roll sticks command a tilt (released = self-level), yaw commands a rate, and the
// throttle stick commands a climb rate (released = altitude hold). The mixer comes from where each rotor
// sits relative to the centre of mass and which way it spins, so any 3+ rotor layout works.
#include <vector>
#include "pw/sim/craft_sim.h"

namespace pw::sim {

struct MultirotorSticks { double climb = 0, yaw = 0, pitch = 0, roll = 0; };   // each -1..1 (pitch +1 = nose down / forward, roll +1 = right)

class MultirotorFC {
public:
    /// Detect rotors (props driven by motor outputs). Returns false if the craft is not a multirotor (< 3 rotors).
    bool attach(const CraftSim& sim);
    bool active() const { return !rotors_.empty(); }
    std::vector<int> outputs() const { std::vector<int> o; for (auto& r : rotors_) o.push_back(r.output); return o; }
    void reset() { hover_ = hoverStart; pitchI_ = rollI_ = 0; }
    /// Compute and apply motor outputs for this step.
    void update(CraftSim& sim, const MultirotorSticks& s, double dt);
    double maxTiltDeg = 35, maxClimb = 6, maxYawRate = 3;
    double kp = 1.6, ki = 1.0, kd = 0.22;   // attitude gains, in throttle units per unit tilt (sin) / rad/s
    double hoverStart = 0.1;                // hover thrust fraction the climb loop starts from (it learns the real one)
    double brake = 0;   // > 0: also lean against horizontal velocity (tilt sine per m/s), so centred sticks hold still (EVOLVE)
private:
    struct Rotor { int output; double x, z, spin; };
    std::vector<Rotor> rotors_;
    double hover_ = 0.1, pitchI_ = 0, rollI_ = 0;
};

} // namespace pw::sim
