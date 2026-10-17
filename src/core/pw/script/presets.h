#pragma once
// Experiment presets (port of Swift Sources/Evolution/Core/Presets.swift, docs/EVOLUTION.md §4.5).
// The three preset documents are the Swift app's own `--make-experiment` output (data/experiments/*.json,
// regenerate with `PlaneWorld --make-experiment "<name>" <file>`), embedded at build time, so the C++ CLI writes
// the same document field for field. Only the craft name is substituted.
#include <optional>
#include <string>
#include <vector>
#include "pw/craft/document.h"

namespace pw::script::presets {
/// "Neural controller", "Craft design", "Co-evolve design + controller".
const std::vector<std::string>& names();
/// The preset as an ExperimentDocument JSON value. Unknown names give "Neural controller" (as in Swift).
json::Value make(const std::string& name, const std::string& craftName = "Trainer");
/// Pretty JSON text of make().
std::string makeJSON(const std::string& name, const std::string& craftName = "Trainer");
/// The preset's JavaScript (scripts.source): neuralJS / designJS.
std::string script(const std::string& name);
/// Standard flight sensors (alt, att, rate, air, vs, aero) added when the craft has no sensor part.
craft::CraftDocument addStandardSensors(const craft::CraftDocument& craft);

/// Example experiments shipped in examples/experiments (file name → JSON text), for tests and the app.
struct Example { std::string file; std::string json; };
const std::vector<Example>& examples();
}
