#include "pw/parity.h"
#include <cmath>
#include <cstdlib>
#include <cstring>
#include "pw/aero.h"

namespace pw::parity {

bool close(double a, double b, double rel, double absFloor) {
    if (std::isnan(a) || std::isnan(b)) return std::isnan(a) && std::isnan(b);
    if (a == b) return true;
    double m = std::fmax(std::fmax(std::fabs(a), std::fabs(b)), absFloor);
    return std::fabs(a - b) <= rel * m;
}
uint64_t ulps(double a, double b) {
    int64_t ia, ib; std::memcpy(&ia, &a, 8); std::memcpy(&ib, &b, 8);
    if (ia < 0) ia = int64_t(0x8000000000000000ull) - ia;
    if (ib < 0) ib = int64_t(0x8000000000000000ull) - ib;
    return ia > ib ? uint64_t(ia - ib) : uint64_t(ib - ia);
}

std::string defaultDir() {
    if (const char* e = std::getenv("PW_PARITY_DIR")) return e;
#ifdef PW_DEFAULT_PARITY_DIR
    return PW_DEFAULT_PARITY_DIR;
#else
    return "tests/parity";
#endif
}

bool loadIndex(const std::string& dir, std::vector<IndexEntry>& out, std::string& err) {
    auto r = json::parseFile(dir + "/index.json");
    if (!r.ok) { err = r.error.empty() ? "parse error" : r.error; return false; }
    for (auto& f : r.value["files"].items())
        out.push_back({f["file"].str(), f["craft"].str(), f["profile"].str(), f["scenario"].str()});
    return !out.empty() || (err = "index has no files", false);
}

bool loadTrajectory(const std::string& path, Trajectory& t, std::string& err) {
    auto r = json::parseFile(path);
    if (!r.ok) { err = path + ": " + r.error; return false; }
    const auto& v = r.value;
    if (v["schema"].str() != "planeworld.parity.trajectory/1") { err = path + ": unexpected schema"; return false; }
    t.file = path; t.craft = v["craft"].str(); t.craftFile = v["craftFile"].str(); t.profile = v["profile"].str();
    t.scenario = v["scenario"].str(); t.source = v["source"].str();
    t.dt = v["dt"].num(); t.steps = int(v["steps"].num()); t.sampleEvery = int(v["sampleEvery"].num());
    for (auto& o : v["outputs"].items()) { t.outputIds.push_back(o["id"].str()); t.outputNames.push_back(o["name"].str()); t.outputKinds.push_back(o["kind"].str()); }
    for (auto& row : v["samples"].items()) {
        if (row.size() != 15) { err = path + ": bad sample row"; return false; }
        Sample s; s.t = row[0].num();
        for (int k = 0; k < 3; ++k) { s.pos[k] = row[1 + k].num(NAN); s.vel[k] = row[4 + k].num(NAN); s.angvel[k] = row[11 + k].num(NAN); }
        for (int k = 0; k < 4; ++k) s.quat[k] = row[7 + k].num(NAN);
        for (auto& o : row[14].items()) s.outputs.push_back(o.num(NAN));
        t.samples.push_back(std::move(s));
    }
    return true;
}

double scheduledCommand(const std::string& kind, int i, double t) {
    if (kind == "servo") return 0.6 * std::sin(2 * kPi * (0.7 + 0.3 * double(i)) * t + 0.5 * double(i));
    if (kind == "motor") return t < 0.2 ? 0 : std::fmin(1, (t - 0.2) / 0.5) * (0.8 + 0.2 * std::sin(3 * t));
    if (kind == "jet") return t < 0.1 ? 0 : 1;
    if (kind == "solid") return t < 0.5 ? 0 : 1;
    return 0;
}

namespace {
struct Acc {
    UnitReport& r; double rel;
    void cmp(double got, double want, const char* what, std::size_t idx) {
        ++r.checked;
        if (got == want || (std::isnan(got) && std::isnan(want))) { ++r.exact; return; }
        double m = std::fmax(std::fabs(got), std::fabs(want));
        double e = m > 0 ? std::fabs(got - want) / m : 0;
        if (e > r.worstRel) r.worstRel = e;
        if (!close(got, want, rel, 1e-300)) {
            if (r.failed++ == 0) r.firstFailure = std::string(what) + "[" + std::to_string(idx) + "]: got " + json::formatNumber(got) + " want " + json::formatNumber(want);
        }
    }
};
}
}

namespace pw::parity {
UnitReport checkUnits(const json::Value& u, double rel) {
    UnitReport r; Acc a{r, rel};
    std::vector<aero::WingParams> params;
    for (auto& p : u["wingParams"].items()) params.emplace_back(p[0].num(), p[1].num(), p[2].num(), p[3].num());
    std::size_t i = 0;
    for (auto& w : u["wing"].items()) {
        const auto& in = w["in"];
        const aero::WingParams& p = params.at(std::size_t(w["p"].num()));
        aero::WingConst k(p);
        auto c = aero::wing(in[0].num(), in[1].num(), in[2].num(), p, in[3].num());
        auto c2 = aero::wing(in[0].num(), in[1].num(), in[2].num(), k, in[3].num());
        const double got[5] = {c.cl, c.cd, c.stalled ? 1.0 : 0.0, c.centerOfPressure, c.hingeCh};
        const double got2[5] = {c2.cl, c2.cd, c2.stalled ? 1.0 : 0.0, c2.centerOfPressure, c2.hingeCh};
        for (int j = 0; j < 5; ++j) { a.cmp(got[j], w["ref"][j].num(), "wing.ref", i); a.cmp(got2[j], w["hoisted"][j].num(), "wing.hoisted", i); }
        // ground effect sampled with h = 0.5 + (alphaDeg + 30) * 0.05, span 4 (see ParityUnits.swift)
        double aiDeg = std::round(in[0].num() / kDeg);
        auto g = aero::groundEffect(0.5 + (aiDeg + 30) * 0.05, 4);
        a.cmp(g.phi, w["ge"][0].num(), "groundEffect.phi", i); a.cmp(g.liftGain, w["ge"][1].num(), "groundEffect.gain", i);
        ++i;
    }
    i = 0;
    for (auto& p : u["prop"].items()) {
        const auto& in = p["in"];
        double P = aero::propPower(in[0].num(), in[1].num());
        a.cmp(P, p["power"].num(), "propPower", i);
        auto o = aero::propThrust(P, in[1].num(), in[3].num(), in[4].num(), in[2].num());
        a.cmp(o.thrust, p["out"][0].num(), "propThrust.T", i); a.cmp(o.advanceRatio, p["out"][1].num(), "propThrust.J", i); a.cmp(o.rps, p["out"][2].num(), "propThrust.rps", i);
        ++i;
    }
    i = 0;
    for (auto& m : u["misc"].items()) {
        const std::string& fn = m["fn"].str(); const auto& in = m["in"];
        double got = NAN;
        if (fn == "jetLapse") got = aero::jetLapse(in[0].num(), in[1].num());
        else if (fn == "spool") got = aero::spool(in[0].num(), in[1].num(), in[2].num());
        else if (fn == "solidProfile") got = aero::solidProfile(in[0].num(), in[1].num(), in[2].num());
        else if (fn == "diskVelocity") got = aero::diskVelocity(in[0].num(), in[1].num(), in[2].num(), in[3].num(), in[4].num() != 0);
        else if (fn == "rotorGroundEffect") got = aero::rotorGroundEffectGain(in[0].num(), in[1].num(), in[2].num());
        a.cmp(got, m["out"].num(), fn.c_str(), i++);
    }
    std::vector<aero::RotorWake> wakes;
    for (auto& d : u["wakeDefs"].items()) {
        aero::RotorWake w;
        auto v3 = [](const json::Value& x) { return Vec3d(x[0].num(), x[1].num(), x[2].num()); };
        w.center = v3(d["center"]); w.axis = v3(d["axis"]); w.cross = v3(d["cross"]);
        w.radius = d["radius"].num(); w.vi = d["vi"].num(); w.vAxial = d["vAxial"].num(); w.swirl = d["swirl"].num();
        w.ducted = d["ducted"].boolean(); w.swirlEnd = d["swirlEnd"].isString() ? HUGE_VAL : d["swirlEnd"].num();
        w.nBlk = int(d["nBlk"].num());
        const auto& b = d["blk"][0];
        w.blkX[0] = b[0].num(); w.blkY[0] = b[1].num(); w.blkZ[0] = b[2].num(); w.blkS[0] = b[3].num(); w.blkR[0] = b[4].num(); w.blkLen[0] = b[5].num();
        wakes.push_back(w);
    }
    i = 0;
    for (auto& s : u["wake"].items()) {
        const auto& w = wakes.at(std::size_t(s["w"].num()));
        Vec3d p(s["p"][0].num(), s["p"][1].num(), s["p"][2].num());
        Vec3d v = aero::wakeInduced(w, p);
        // Velocity components that are tiny relative to the vector magnitude are compared against that magnitude.
        double mag = std::fmax(std::fabs(s["v"][0].num()), std::fmax(std::fabs(s["v"][1].num()), std::fabs(s["v"][2].num())));
        const double g[3] = {v.x, v.y, v.z};
        for (int j = 0; j < 3; ++j) {
            double want = s["v"][j].num();
            ++r.checked;
            if (g[j] == want) { ++r.exact; continue; }
            double e = std::fabs(g[j] - want) / std::fmax(mag, 1e-300);
            if (e > r.worstRel) r.worstRel = e;
            if (e > rel && r.failed++ == 0) r.firstFailure = "wake[" + std::to_string(i) + "]: got " + json::formatNumber(g[j]) + " want " + json::formatNumber(want);
        }
        ++i;
    }
    return r;
}
}
