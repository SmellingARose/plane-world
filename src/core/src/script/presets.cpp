// Experiment presets (port of Swift Core/Presets.swift). See pw/script/presets.h.
#include "pw/script/presets.h"

#include <cstring>

namespace pw::script::embedded_experiments {
struct Blob { const char* key; const char* data; std::size_t size; };
const Blob* blobs();
}

namespace pw::script::presets {
namespace {
const char* fileFor(const std::string& name) {
    if (name == "Craft design") return "craft-design.json";
    if (name == "Co-evolve design + controller") return "coevolve.json";
    return "neural-controller.json";
}
const char* prefixFor(const std::string& name) {
    if (name == "Craft design") return "Craft design";
    if (name == "Co-evolve design + controller") return "Co-evolve";
    return "Neural controller";
}
std::string blob(const char* key) {
    for (auto* b = embedded_experiments::blobs(); b->key; ++b)
        if (std::strcmp(b->key, key) == 0) return std::string(b->data, b->size);
    return {};
}
// json::Value has no in-place member replace; rebuild the object with `key` replaced.
json::Value withMember(const json::Value& o, const std::string& key, json::Value v) {
    json::Value out = json::Value::object();
    bool done = false;
    for (auto& [k, x] : o.members()) {
        if (k == key && !done) { out.set(k, v); done = true; }
        else out.set(k, x);
    }
    if (!done) out.set(key, std::move(v));
    return out;
}
} // namespace

const std::vector<std::string>& names() {
    static const std::vector<std::string> n = {"Neural controller", "Craft design", "Co-evolve design + controller"};
    return n;
}

json::Value make(const std::string& name, const std::string& craftName) {
    auto r = json::parse(blob(fileFor(name)));
    json::Value e = r.value;
    e = withMember(e, "name", json::Value::string(std::string(prefixFor(name)) + " \xE2\x80\x94 " + craftName));
    json::Value crafts = json::Value::array();
    json::Value ref = json::Value::object();
    ref.set("name", json::Value::string(craftName));
    crafts.push(std::move(ref));
    return withMember(e, "crafts", std::move(crafts));
}

std::string makeJSON(const std::string& name, const std::string& craftName) { return json::dump(make(name, craftName), 2) + "\n"; }

std::string script(const std::string& name) { return make(name)["scripts"]["source"].str(); }

craft::CraftDocument addStandardSensors(const craft::CraftDocument& c) {
    for (auto& p : c.parts) if (p.partType() == craft::PartType::Sensor) return c;
    craft::CraftDocument out = c;
    const char* s[][3] = {{"sn-alt", "alt", "altitudeAGL"}, {"sn-att", "att", "attitude"}, {"sn-rate", "rate", "angularRate"},
                          {"sn-air", "air", "airspeed"},    {"sn-vs", "vs", "verticalSpeed"}, {"sn-aero", "aero", "aero"}};
    for (auto& x : s) {
        auto p = craft::CraftPart::make(x[0], craft::PartType::Sensor, x[1]);
        p.setParam("kind", std::string(x[2]));
        out.parts.push_back(std::move(p));
    }
    return out;
}

const std::vector<Example>& examples() {
    static const std::vector<Example> ex = [] {
        std::vector<Example> v;
        for (auto* b = embedded_experiments::blobs(); b->key; ++b)
            if (std::strncmp(b->key, "examples/", 9) == 0) v.push_back({b->key + 9, std::string(b->data, b->size)});
        return v;
    }();
    return ex;
}
}
