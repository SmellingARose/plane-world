#pragma once
// Liquid rocket engine layout (PartType::Rocket), shared by the render mesh (craft::partMesh) and the simulation
// (gimbal pivot = thrust application point, rendered gimbal pose). Part-local frame: thrust along +x, nozzle exit
// plane at x = -len/2, gimbal block on top (x = +len/2). From the top down: gimbal block, injector dome, cylindrical
// combustion chamber, 30-degree convergent section, throat, Rao 80 % thrust-optimised bell (circular arc of 0.382 r_t
// to the inflection angle theta_n, then a quadratic Bezier to the exit angle theta_e).
#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

namespace pw {

struct RocketGeometry {
    double len = 1, rExit = 0.3, expansion = 12;   // part params "len", "r" (nozzle exit radius), "expansion" (A_e / A_t)
    double rThroat = 0, rChamber = 0;
    double xExit = 0, xThroat = 0, xChamberBot = 0, xChamberTop = 0, xInjTop = 0, xPivot = 0, xTop = 0;
    double blockH = 0;           // gimbal block height (pivot at its centre)
    double nozzleLen = 0;        // throat -> exit
    double thetaN = 0, thetaE = 0;   // bell inflection / exit wall angles (rad)
    double rJoint = 0;           // nozzle-extension joint radius (regen-cooled section above, extension below)
};

/// Engine layout for exit radius r, overall length len and nozzle area ratio (<= 1: 12).
inline RocketGeometry rocketGeometry(double r, double len, double expansion) {
    RocketGeometry g;
    g.len = std::max(len, 0.05); g.rExit = std::max(r, 0.01); g.expansion = expansion > 1 ? expansion : 12;
    const double kDeg = 3.14159265358979323846 / 180;
    g.rThroat = g.rExit / std::sqrt(g.expansion);
    g.rChamber = std::clamp(g.rThroat * std::sqrt(3.2), g.rThroat * 1.3, std::max(g.rThroat * 1.3, 0.55 * g.rExit));   // contraction ratio ~3.2
    g.xTop = g.len / 2; g.xExit = -g.len / 2;
    g.blockH = 0.09 * g.len;
    g.xPivot = g.xTop - 0.5 * g.blockH;
    g.xInjTop = g.xTop - g.blockH;
    g.xChamberTop = g.xInjTop - 0.45 * g.rChamber;   // injector dome
    // Rao 80 % bell angles vs area ratio (fit to Rao's charts: eps 10 -> 26.7 / 10.1 deg, 25 -> 30 / 8.5, 100 -> 34.9 / 6.2)
    const double l10 = std::log10(g.expansion);
    g.thetaN = (18.5 + 8.2 * l10) * kDeg; g.thetaE = std::max(4.0, 14 - 3.9 * l10) * kDeg;
    const double convLen = 0.75 * g.rThroat + std::max(0.0, g.rChamber - 1.201 * g.rThroat) / std::tan(30 * kDeg);
    double nozLen = 0.8 * (g.rExit - g.rThroat) / std::tan(15 * kDeg);
    const double avail = g.xChamberTop - g.xExit;
    const double minCyl = 0.8 * g.rChamber;
    if (avail - convLen - nozLen < minCyl) nozLen = std::max(0.3 * nozLen, avail - convLen - minCyl);   // short part: compress the bell
    g.nozzleLen = std::max(nozLen, 0.05 * g.len);
    g.xThroat = g.xExit + g.nozzleLen;
    g.xChamberBot = g.xThroat + convLen;
    g.rJoint = g.rThroat * std::sqrt(std::clamp(0.4 * g.expansion, 1.5, 9.0));
    return g;
}

/// Inner contour (x, r) from the chamber wall down to the exit: chamber cylinder end, 30-degree convergent cone,
/// 1.5 r_t throat entry arc, 0.382 r_t throat exit arc, Bezier bell. `n` = points on the bell.
inline std::vector<std::pair<double, double>> rocketContour(const RocketGeometry& g, int n = 24) {
    std::vector<std::pair<double, double>> c;
    const double rt = g.rThroat, kDeg = 3.14159265358979323846 / 180;
    c.push_back({g.xChamberTop, g.rChamber});
    c.push_back({g.xChamberBot, g.rChamber});
    // convergent cone ends at the 1.5 rt entry arc (30 deg tangent)
    for (int i = 6; i >= 0; --i) {
        const double ph = 30 * kDeg * i / 6;
        c.push_back({g.xThroat + 1.5 * rt * std::sin(ph), rt + 1.5 * rt * (1 - std::cos(ph))});
    }
    // divergent arc to the inflection point
    const double Rd = 0.382 * rt;
    for (int i = 1; i <= 4; ++i) {
        const double ph = g.thetaN * i / 4;
        c.push_back({g.xThroat - Rd * std::sin(ph), rt + Rd * (1 - std::cos(ph))});
    }
    // Bezier: N (inflection) -> E (exit), control point at the intersection of the two wall tangents
    const double dN = Rd * std::sin(g.thetaN), rN = rt + Rd * (1 - std::cos(g.thetaN));
    const double dE = g.nozzleLen, rE = g.rExit;
    const double tn = std::tan(g.thetaN), te = std::tan(g.thetaE);
    double dQ = (rE - rN + tn * dN - te * dE) / std::max(1e-6, tn - te);
    dQ = std::clamp(dQ, dN, dE);
    double rQ = std::clamp(rN + tn * (dQ - dN), rN, rE);
    for (int i = 1; i <= n; ++i) {
        const double t = double(i) / n, a = (1 - t) * (1 - t), b = 2 * t * (1 - t), cc = t * t;
        const double d = a * dN + b * dQ + cc * dE, rr = a * rN + b * rQ + cc * rE;
        c.push_back({g.xThroat - d, rr});
    }
    return c;
}

} // namespace pw
