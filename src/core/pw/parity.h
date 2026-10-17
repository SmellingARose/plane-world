#pragma once
// Parity harness data (tests/parity, written by `PlaneWorld --export-parity <dir>` from the Swift app).
#include <string>
#include <vector>
#include "pw/json.h"

namespace pw::parity {

/// Relative comparison used across the harness: |a-b| <= rel * max(|a|,|b|, floor).
bool close(double a, double b, double rel = 1e-9, double absFloor = 1e-300);
/// Distance in units in the last place (0 = bit-identical).
uint64_t ulps(double a, double b);

struct Sample {
    double t = 0;
    double pos[3]{}, vel[3]{}, quat[4]{}, angvel[3]{};
    std::vector<double> outputs;
};
struct Trajectory {
    std::string file, craft, craftFile, profile, scenario, source;
    double dt = 0;
    int steps = 0, sampleEvery = 0;
    std::vector<std::string> outputIds, outputNames, outputKinds;
    std::vector<Sample> samples;
};
struct IndexEntry { std::string file, craft, profile, scenario; };

std::string defaultDir();   // $PW_PARITY_DIR or the source tree's tests/parity
bool loadIndex(const std::string& dir, std::vector<IndexEntry>& out, std::string& err);
bool loadTrajectory(const std::string& path, Trajectory& out, std::string& err);

/// Scripted output schedule used by the exporter (ParityExport.command in Swift): kind = servo|motor|jet|solid.
double scheduledCommand(const std::string& kind, int index, double t);

struct UnitReport { int checked = 0, failed = 0, exact = 0; double worstRel = 0; std::string firstFailure; };
/// Re-evaluates every wing / prop / misc / wake sample of units.json with pw::aero and compares (rel tolerance).
UnitReport checkUnits(const json::Value& units, double rel = 1e-9);
}
