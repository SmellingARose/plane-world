#pragma once
// Headless training entry point shared by pwcli and the evolution core.
// pwcli parses and validates the Swift `--train` flags (docs/EVOLUTION.md §10) and applies every override to the
// experiment document; the evolution core (P2a, pw/evolution) registers the function that runs the request.
#include <string>
#include "pw/json.h"
#include "pw/script/runtime.h"

namespace pw::train {
struct Request {
    json::Value experiment;          // overrides applied (generations, population, workers, seed, aero)
    std::string experimentPath;      // for resolving relative craft / world paths
    std::string outDir;              // empty: the experiment's run directory under the data root
    bool resume = false;             // continue from run.json in outDir when present
    bool currentAsFlat = false;      // world source "current" trains on the flat world
    script::Engine engine = script::Engine::Auto;
};
using Handler = int (*)(const Request&);   // returns the process exit code
void setHandler(Handler h);
Handler handler();                     // nullptr until the evolution core registers
}
