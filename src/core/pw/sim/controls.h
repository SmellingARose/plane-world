#pragma once
// Pilot controls: how a person (or a script) flies a craft.
//
//   keys / sliders / scripts ──► AXES ──► CONTROLLER ──► OUTPUTS (servos, motors, jets, ...)
//
// An axis is a named pilot command ("pitch", "throttle", ...) with an optional key pair. The controller turns the
// axis values into output values, so one key can drive several outputs (elevons, a quad's four motors) and an
// output can be driven by several axes. Controllers:
//   direct      — each output = Σ gain × axis (a mix table). With no "controls" block, a craft gets one axis per
//                 output that has part keybinds ("keys"), mixed 1:1 — the classic per-output behaviour.
//   multirotor  — angle-mode flight controller (see multirotor.h) on axes "throttle" (climb rate), "yaw",
//                 "pitch", "roll"; it computes all rotor throttles every step.
//
// Craft JSON (optional, top level):
//   "controls": {
//     "controller": "direct" | "multirotor",
//     "axes": [ { "name": "pitch", "keys": { "pos": "up", "neg": "down", "mode": "spring", "rate": 3 }, "lo": -1, "hi": 1 } ],
//     "mix":  [ { "axis": "pitch", "output": "Elevon L", "gain": 1 }, { "axis": "roll", "output": "Elevon L", "gain": -1 } ]
//   }
// "output" is an output's part id or name. Adding a controller = a ControlSystem branch + a doc line here.
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/sim/multirotor.h"

namespace pw::sim {

class CraftSim;

enum class ControllerKind : uint8_t { Direct, Multirotor };

struct ControlAxis {
    std::string name;
    craft::OutputKeybind keys;
    double lo = -1, hi = 1;
    double value = 0;
};

struct ControlMix { std::string axis, output; double gain = 1; };

struct ControlScheme {
    ControllerKind controller = ControllerKind::Direct;
    std::vector<ControlAxis> axes;
    std::vector<ControlMix> mix;   // direct controller only
    /// The craft's "controls" block, or the legacy per-output keybinds when it has none. `flightDoc` = the document
    /// FLY loads (outputs::prepareForFlight), so automatic motors are included.
    static ControlScheme fromDocument(const craft::CraftDocument& flightDoc);
    craft::Value toJson() const;
};

class ControlSystem {
public:
    /// Resolve names against the loaded sim. Resets axis values.
    void load(const ControlScheme& scheme, const CraftSim& sim);
    void reset();
    /// Advance key-driven axes (`held(key)` = key is down) and drive the outputs. Returns true if an axis moved.
    bool step(CraftSim& sim, const std::function<bool(const std::string&)>& held, double dt);
    /// Set an axis directly (slider, script, gamepad). Takes effect on the next step.
    void setAxis(int i, double v);
    int axisIndex(const std::string& name) const;
    const std::vector<ControlAxis>& axes() const { return scheme_.axes; }
    ControllerKind controller() const { return scheme_.controller; }
    /// True if the controller writes every listed output each step (the per-output sliders are then read-only).
    bool ownsOutput(int simOutput) const;
    bool usesKey(const std::string& key) const;
private:
    struct Term { int axis, output; double gain; };
    ControlScheme scheme_;
    std::vector<Term> terms_;
    std::vector<int> owned_;
    MultirotorFC fc_;
    int aThrottle_ = -1, aYaw_ = -1, aPitch_ = -1, aRoll_ = -1;
};

const char* controllerName(ControllerKind k);

} // namespace pw::sim
