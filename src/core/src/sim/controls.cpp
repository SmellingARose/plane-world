#include "pw/sim/controls.h"
#include <algorithm>
#include "pw/craft/outputs.h"
#include "pw/sim/craft_sim.h"

namespace pw::sim {
using craft::Value;

const char* controllerName(ControllerKind k) {
    switch (k) { case ControllerKind::Multirotor: return "multirotor"; case ControllerKind::Rocket: return "rocket"; default: return "direct"; }
}

namespace {
craft::OutputKeybind keys(const char* pos, const char* neg, craft::OutputKeybind::Mode mode, double rate) {
    craft::OutputKeybind k; k.pos = pos; k.neg = neg; k.mode = mode; k.rate = rate; return k;
}
// Default sticks for a multirotor: W/S climb, A/D yaw, arrows tilt (all spring back, i.e. hover and self-level).
// Default sticks for a gimballed rocket: W/S ramp the throttle (it stays where you leave it), arrows tilt.
std::vector<ControlAxis> rocketAxes() {
    using M = craft::OutputKeybind::Mode;
    ControlAxis thr{"throttle", keys("w", "s", M::Ramp, 0.5)}; thr.lo = 0;
    return {thr, {"pitch", keys("up", "down", M::Spring, 4)}, {"yaw", keys("right", "left", M::Spring, 4)}};
}
std::vector<ControlAxis> multirotorAxes() {
    using M = craft::OutputKeybind::Mode;
    return {{"throttle", keys("w", "s", M::Spring, 4)}, {"yaw", keys("d", "a", M::Spring, 4)},
            {"pitch", keys("up", "down", M::Spring, 4)}, {"roll", keys("right", "left", M::Spring, 4)}};
}
} // namespace

ControlScheme ControlScheme::fromDocument(const craft::CraftDocument& doc) {
    ControlScheme s;
    if (const Value* c = doc.extra.find("controls"); c && c->isObject()) {
        if (auto k = craft::jsonString((*c)["controller"])) {
            if (*k == "multirotor") s.controller = ControllerKind::Multirotor;
            else if (*k == "rocket") s.controller = ControllerKind::Rocket;
        }
        if ((*c)["axes"].isArray())
            for (const Value& a : (*c)["axes"].items()) {
                ControlAxis x; x.name = craft::jsonString(a["name"]).value_or("");
                if (x.name.empty()) continue;
                if (auto k = craft::keybindFromJson(a["keys"])) x.keys = *k;
                x.lo = craft::jsonDouble(a["lo"]).value_or(-1); x.hi = craft::jsonDouble(a["hi"]).value_or(1);
                s.axes.push_back(std::move(x));
            }
        if ((*c)["mix"].isArray())
            for (const Value& m : (*c)["mix"].items())
                s.mix.push_back({craft::jsonString(m["axis"]).value_or(""), craft::jsonString(m["output"]).value_or(""), craft::jsonDouble(m["gain"]).value_or(1)});
        if (s.axes.empty()) {
            if (s.controller == ControllerKind::Multirotor) s.axes = multirotorAxes();
            else if (s.controller == ControllerKind::Rocket) s.axes = rocketAxes();
        }
        return s;
    }
    // legacy: one axis per output with part keybinds, mixed 1:1
    for (const auto& o : craft::outputs::list(doc)) {
        const craft::CraftPart* p = doc.part(std::string_view(o.id));
        auto kb = p ? craft::keybind(*p) : std::nullopt;
        if (!kb || kb->isEmpty()) continue;
        s.axes.push_back({o.name, *kb, o.lo, o.hi, 0});
        s.mix.push_back({o.name, o.id, 1});
    }
    return s;
}

Value ControlScheme::toJson() const {
    Value o = Value::object();
    o.set("controller", Value::string(controllerName(controller)));
    Value ax = Value::array();
    for (const auto& a : axes) {
        Value v = Value::object();
        v.set("name", Value::string(a.name)); v.set("keys", craft::toJson(a.keys));
        v.set("lo", Value::number(a.lo)); v.set("hi", Value::number(a.hi));
        ax.push(v);
    }
    o.set("axes", ax);
    if (!mix.empty()) {
        Value mx = Value::array();
        for (const auto& m : mix) {
            Value v = Value::object();
            v.set("axis", Value::string(m.axis)); v.set("output", Value::string(m.output)); v.set("gain", Value::number(m.gain));
            mx.push(v);
        }
        o.set("mix", mx);
    }
    return o;
}

void ControlSystem::load(const ControlScheme& scheme, const CraftSim& sim) {
    scheme_ = scheme;
    terms_.clear(); owned_.clear();
    aThrottle_ = axisIndex("throttle"); aYaw_ = axisIndex("yaw"); aPitch_ = axisIndex("pitch"); aRoll_ = axisIndex("roll");
    if (scheme_.controller == ControllerKind::Multirotor && fc_.attach(sim)) owned_ = fc_.outputs();
    else if (scheme_.controller == ControllerKind::Rocket && rocket_.attach(sim)) owned_ = rocket_.outputs();
    else {
        scheme_.controller = ControllerKind::Direct;   // the craft lacks what the controller needs (< 3 rotors / no engine)
        for (const auto& m : scheme_.mix) {
            const int a = axisIndex(m.axis), o = sim.outputIndex(m.output);
            if (a < 0 || o < 0) continue;
            terms_.push_back({a, o, m.gain});
            if (std::find(owned_.begin(), owned_.end(), o) == owned_.end()) owned_.push_back(o);
        }
    }
    reset();
}

void ControlSystem::reset() {
    for (auto& a : scheme_.axes) a.value = 0;
    fc_.reset(); rocket_.reset();
}

int ControlSystem::axisIndex(const std::string& name) const {
    for (std::size_t i = 0; i < scheme_.axes.size(); ++i) if (scheme_.axes[i].name == name) return int(i);
    return -1;
}

void ControlSystem::setAxis(int i, double v) {
    if (i < 0 || i >= int(scheme_.axes.size())) return;
    auto& a = scheme_.axes[std::size_t(i)];
    a.value = std::clamp(v, a.lo, a.hi);
}

bool ControlSystem::ownsOutput(int o) const { return std::find(owned_.begin(), owned_.end(), o) != owned_.end(); }

bool ControlSystem::usesKey(const std::string& key) const {
    for (const auto& a : scheme_.axes) if ((a.keys.pos && *a.keys.pos == key) || (a.keys.neg && *a.keys.neg == key)) return true;
    return false;
}

bool ControlSystem::step(CraftSim& sim, const std::function<bool(const std::string&)>& held, double dt) {
    bool moved = false;
    for (auto& a : scheme_.axes) {
        if (a.keys.isEmpty()) continue;
        const bool up = a.keys.pos && held(*a.keys.pos), down = a.keys.neg && held(*a.keys.neg);
        const double v = craft::stepKeybind(a.keys, a.value, a.lo, a.hi, up, down, dt);
        if (v != a.value) { a.value = v; moved = true; }
    }
    auto axis = [&](int i) { return i >= 0 ? scheme_.axes[std::size_t(i)].value : 0.0; };
    if (scheme_.controller == ControllerKind::Multirotor) {
        fc_.update(sim, {axis(aThrottle_), axis(aYaw_), axis(aPitch_), axis(aRoll_)}, dt);
    } else if (scheme_.controller == ControllerKind::Rocket) {
        rocket_.update(sim, {axis(aThrottle_), axis(aPitch_), axis(aYaw_)}, dt);
    } else if (moved) {
        // Only rewrite mixed outputs when an axis moves, so sliders / autopilots can still set them in between.
        std::vector<double> sum(sim.outputs().size(), 0.0);
        for (const auto& t : terms_) sum[std::size_t(t.output)] += t.gain * axis(t.axis);
        for (int o : owned_) sim.setOutput(o, sum[std::size_t(o)]);
    }
    return moved;
}

} // namespace pw::sim
