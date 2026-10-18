// Built-in procedural world presets. See pw/world/presets.h.
//
// Manhattan (Midtown): everything is generated from a handful of rules on the real street grid, so the file stays
// small and the result is deterministic. Units are metres. Local frame: u = cross-town (east +, 0 at Fifth Avenue),
// v = up-town (north +, 0 at 34th Street, 80 m per numbered street). The grid is rotated 29 deg clockwise from true
// north like the real one; world north is -z, east is +x. The world origin sits near Rockefeller Center.
#include "pw/world/presets.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <utility>
#include <vector>

namespace pw::world::presets {
using json::Value;

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double G = 10;                 // flat ground level (above the beach band so the land beyond renders as grass)
constexpr double kStreet = 80;           // one numbered street
constexpr double kFirstSt = 30, kLastSt = 96;
constexpr double kOriginU = -300, kOriginV = 13 * kStreet;   // world origin: 6th Ave-ish at 47th St

double stV(double n) { return (n - 34) * kStreet; }

struct Rng {   // xorshift64*: identical on every platform
    uint64_t s;
    double next() { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return double((s * 2685821657736338717ull) >> 11) * (1.0 / 9007199254740992.0); }
    double range(double a, double b) { return a + (b - a) * next(); }
    bool chance(double p) { return next() < p; }
    template <class T, std::size_t N> const T& pick(const std::array<T, N>& a) { return a[std::min<std::size_t>(N - 1, std::size_t(next() * N))]; }
};

struct Col { double r, g, b; Col operator*(double k) const { return {r * k, g * k, b * k}; } };
namespace pal {
constexpr Col brownstone{0.19, 0.115, 0.085}, redBrick{0.30, 0.13, 0.09}, darkBrick{0.20, 0.10, 0.08}, buffBrick{0.46, 0.38, 0.27},
              limestone{0.56, 0.51, 0.42}, whiteStone{0.63, 0.61, 0.56}, granite{0.13, 0.13, 0.14}, terracotta{0.50, 0.36, 0.27},
              deco{0.58, 0.54, 0.47}, glassBlue{0.16, 0.22, 0.29}, glassGreen{0.15, 0.25, 0.24}, glassDark{0.07, 0.09, 0.11},
              glassSilver{0.34, 0.38, 0.42}, steel{0.70, 0.72, 0.75}, copper{0.22, 0.40, 0.34}, concrete{0.42, 0.41, 0.39},
              asphalt{0.055, 0.055, 0.06}, sidewalk{0.40, 0.39, 0.37}, plaza{0.48, 0.46, 0.42}, grass{0.08, 0.19, 0.05},
              lawn{0.14, 0.28, 0.07}, wood{0.26, 0.16, 0.09}, mech{0.33, 0.33, 0.34}, navyGrey{0.27, 0.29, 0.31};
}

enum class Pat { None, Windows, Glass };

struct Rect { double u0, u1, v0, v1; bool contains(double u, double v) const { return u > u0 && u < u1 && v > v0 && v < v1; }
              bool overlaps(const Rect& o) const { return u0 < o.u1 && o.u0 < u1 && v0 < o.v1 && o.v0 < v1; } };

class City {
public:
    explicit City(WorldDocument& d) : d_(d) {}
    WorldDocument& d_;
    Rng rng{0x6D616E68617474ull};
    const double th = 29.0 * kPi / 180.0, c = std::cos(29.0 * kPi / 180.0), s = std::sin(29.0 * kPi / 180.0);
    const Quatd rot = Quatd::angleAxis(-29.0 * kPi / 180.0, {0, 1, 0});   // local x -> u axis, local -z -> v axis

    Vec3d W(double u, double v, double y = 0) const {
        u -= kOriginU; v -= kOriginV;
        return Vec3d{u * c + v * s, y, u * s - v * c};
    }
    std::vector<double> pt(double u, double v) const { Vec3d p = W(u, v); return {p.x, p.z}; }

    /// One primitive: footprint centred at (u, v), extents w (cross-town) x dp (up-town), from y0 to y0 + h above ground.
    void prim(const char* shape, const char* kind, double u, double v, double y0, double w, double dp, double h, Col col,
              Pat pat = Pat::None, bool collide = true, double rough = 0.85, double metal = 0, double emit = 0) {
        if (w <= 0.05 || dp <= 0.05 || h <= 0.01) return;
        JsonObject p;
        Value cv = Value::array(); cv.push(Value::number(col.r)); cv.push(Value::number(col.g)); cv.push(Value::number(col.b));
        p.set("color", cv);
        if (shape[0] != 'b') p.set("shape", Value::string(shape));
        if (pat != Pat::None) p.set("pattern", Value::string(pat == Pat::Glass ? "glass" : "windows"));
        if (rough != 0.85) p.set("roughness", Value::number(rough));
        if (metal > 0) p.set("metallic", Value::number(metal));
        if (emit > 0) p.set("emissive", Value::number(emit));
        if (!collide) p.set("collide", Value::fromBool(false));
        d_.placeProp(kind, std::nullopt, Transform(W(u, v, G + y0 + h * 0.5), rot), {w, h, dp}, false, std::move(p));
    }
    void box(double u, double v, double y0, double w, double dp, double h, Col col, Pat pat = Pat::Windows, bool collide = true,
             double rough = 0.85, double metal = 0, double emit = 0) { prim("box", "building", u, v, y0, w, dp, h, col, pat, collide, rough, metal, emit); }
    void slab(double u, double v, double w, double dp, double top, Col col, double rough = 0.95) {   // ground cover, no collision
        prim("box", "ground", u, v, top - 0.5, w, dp, 0.5, col, Pat::None, false, rough);
    }
    void cyl(double u, double v, double y0, double dia, double h, Col col, bool collide = true, double rough = 0.85, double metal = 0, Pat pat = Pat::None) {
        prim("cylinder", "building", u, v, y0, dia, dia, h, col, pat, collide, rough, metal);
    }
    void cone(double u, double v, double y0, double dia, double h, Col col, bool collide = true, double rough = 0.6, double metal = 0) {
        prim("cone", "building", u, v, y0, dia, dia, h, col, Pat::None, collide, rough, metal);
    }
    void lake(const char* id, const std::vector<std::vector<double>>& uv, double level = 0.35) {
        JsonObject l; l.set("id", Value::string(id));
        l.set("level", Value::number(G + level)); l.set("surfaceHeight", Value::number(G + level));
        Value pts = Value::array();
        for (auto& q : uv) { auto p = pt(q[0], q[1]); Value a = Value::array(); a.push(Value::number(p[0])); a.push(Value::number(p[1])); pts.push(a); }
        l.set("points", pts); l.set("outline", pts);
        d_.water.lakes.push_back(l);
    }
    void lakeRect(const char* id, const Rect& r) { lake(id, {{r.u0, r.v0}, {r.u1, r.v0}, {r.u1, r.v1}, {r.u0, r.v1}}); }
    void treeStroke(double u, double v, double radius, double perHa, int species) {   // species: 1 oak, 2 birch
        auto p = pt(u, v);
        Value r = Value::array();
        for (double x : {0.0, p[0], p[1], radius, perHa, double(species)}) r.push(Value::number(x));
        strokes_.push(r);
    }
    Value strokes_ = Value::array();

    // ------------------------------------------------------------------ rooftop details
    void waterTower(double u, double v, double roof) {
        const double dia = rng.range(4.5, 6.5), h = dia * rng.range(0.9, 1.2);
        box(u, v, roof, dia * 0.9, dia * 0.9, 2.6, pal::mech * 0.6, Pat::None, false);           // steel stand
        cyl(u, v, roof + 2.6, dia, h, pal::wood * rng.range(0.85, 1.2), false, 0.95);
        cone(u, v, roof + 2.6 + h, dia * 1.05, dia * 0.35, pal::wood * 0.6, false, 0.9);
    }
    void roofDetails(double u, double v, double w, double dp, double roof, bool masonry, bool allowTower) {
        if (masonry && w > 7 && dp > 7 && roof < 110 && rng.chance(allowTower ? 0.4 : 0)) {
            waterTower(u + rng.range(-0.25, 0.25) * w, v + rng.range(-0.25, 0.25) * dp, roof);
        }
        if (w > 12 && dp > 12 && roof > 25 && rng.chance(0.75)) {
            const double mw = w * rng.range(0.3, 0.55), md = dp * rng.range(0.3, 0.55);
            box(u + rng.range(-0.15, 0.15) * w, v + rng.range(-0.15, 0.15) * dp, roof, mw, md, rng.range(3, 6), pal::mech * rng.range(0.8, 1.2), Pat::None, false);
        }
    }
    void cornice(double u, double v, double w, double dp, double roof, Col col) {
        box(u, v, roof - 1.2, w + 1.0, dp + 1.0, 1.2, col * 0.7, Pat::None, false);
    }

    // ------------------------------------------------------------------ building massing
    /// A generic building on a lot (rect in local coordinates), height h, by style.
    void building(const Rect& r, double h, int style, Col col, bool roofStuff = true) {
        const double u = 0.5 * (r.u0 + r.u1), v = 0.5 * (r.v0 + r.v1), w = r.u1 - r.u0, dp = r.v1 - r.v0;
        if (style == 0) {                 // brownstone / tenement / low masonry
            box(u, v, 0, w, dp, h, col, Pat::Windows);
            if (w > 6) cornice(u, v, w, dp, h, col);
            if (roofStuff) roofDetails(u, v, w, dp, h, true, true);
        } else if (style == 1) {          // pre-war masonry, maybe one setback
            if (h > 55 && w > 18 && dp > 18 && rng.chance(0.6)) {
                const double h1 = h * rng.range(0.6, 0.78), in = rng.range(3, 6);
                box(u, v, 0, w, dp, h1, col, Pat::Windows);
                cornice(u, v, w, dp, h1, col);
                box(u, v, h1, w - 2 * in, dp - 2 * in, h - h1, col, Pat::Windows);
                if (roofStuff) roofDetails(u, v, w - 2 * in, dp - 2 * in, h, true, true);
            } else {
                box(u, v, 0, w, dp, h, col, Pat::Windows);
                cornice(u, v, w, dp, h, col);
                if (roofStuff) roofDetails(u, v, w, dp, h, true, true);
            }
        } else if (style == 2) {          // modern glass: podium + shaft, maybe a setback, mechanical crown
            double y = 0, cw = w, cd = dp;
            if (w > 26 && dp > 26 && rng.chance(0.7)) {
                const double ph = rng.range(12, 24);
                box(u, v, 0, w, dp, ph, rng.chance(0.5) ? pal::granite : col * 1.3, Pat::Windows);
                y = ph; cw = w - rng.range(4, 9); cd = dp - rng.range(4, 9);
            }
            if (h > 140 && rng.chance(0.5)) {
                const double h1 = y + (h - y) * rng.range(0.55, 0.75);
                box(u, v, y, cw, cd, h1 - y, col, Pat::Glass, true, 0.3);
                y = h1; cw *= rng.range(0.72, 0.85); cd *= rng.range(0.72, 0.85);
            }
            box(u, v, y, cw, cd, h - y, col, Pat::Glass, true, 0.3);
            box(u, v, h, cw * 0.7, cd * 0.7, rng.range(4, 9), pal::glassDark, Pat::None, false, 0.4);
            if (h > 180 && rng.chance(0.25)) cyl(u, v, h, 1.2, rng.range(20, 50), pal::steel, true, 0.4, 0.6);
        } else {                          // pre-war wedding cake (setback tiers, crown, maybe an antenna)
            const double fr[4] = {0.0, rng.range(0.25, 0.35), rng.range(0.5, 0.62), rng.range(0.75, 0.85)};
            double cw = w, cd = dp;
            for (int k = 0; k < 4; ++k) {
                const double y0 = h * fr[k], y1 = k < 3 ? h * fr[k + 1] : h;
                box(u, v, y0, cw, cd, y1 - y0, col, Pat::Windows);
                if (k < 3) cornice(u, v, cw, cd, y1, col);
                cw *= rng.range(0.68, 0.82); cd *= rng.range(0.68, 0.82);
            }
            box(u, v, h, cw, cd, h * 0.04 + 3, col * 0.85, Pat::None);
            if (rng.chance(0.4)) cone(u, v, h + h * 0.04 + 3, std::min(cw, cd), h * 0.06 + 4, rng.chance(0.5) ? pal::copper : pal::steel, true, 0.5, 0.3);
            else if (rng.chance(0.4)) cyl(u, v, h + h * 0.04 + 3, 1.0, h * 0.12, pal::steel, true, 0.4, 0.6);
        }
    }
};

// ---------------------------------------------------------------------- grid
struct Avenue { const char* name; double u, width; };
const Avenue kAves[] = {
    {"11th", -1680, 30}, {"10th", -1400, 30}, {"9th", -1120, 30}, {"8th", -840, 30}, {"7th", -560, 30}, {"6th", -280, 30},
    {"5th", 0, 30}, {"Madison", 130, 25}, {"Park", 260, 43}, {"Lexington", 390, 25}, {"3rd", 580, 30}, {"2nd", 780, 30}, {"1st", 980, 30},
};
constexpr int kAveCount = int(sizeof(kAves) / sizeof(kAves[0]));
constexpr double kWestShore = -1830, kEastShore = 1110;        // 12th Ave / FDR Drive bulkheads
const double kWideStreets[] = {34, 42, 57, 59, 72, 79, 86, 96};
double streetWidth(int n) { for (double w : kWideStreets) if (int(w) == n) return 30; return 18; }

/// Broadway's centre line: Madison Sq (23rd, 5th) - Herald Sq (34th, 6th) - Times Sq (45th, 7th) - Columbus Circle (59th, 8th),
/// then up the Upper West Side between Amsterdam and West End.
double broadwayU(double v) {
    const double n = v / kStreet + 34;
    if (n < 34) return -280 + (34 - n) * (280.0 / 11);
    if (n < 45) return -280 - (n - 34) * (280.0 / 11);
    if (n < 59) return -560 - (n - 45) * (280.0 / 14);
    return -840 - std::min(n - 59, 12.0) * (300.0 / 12);
}

double gauss(double u, double v, double cu, double cn, double su, double sn) {
    const double du = (u - cu) / su, dn = (v / kStreet + 34 - cn) / sn;
    return std::exp(-(du * du + dn * dn));
}

// ---------------------------------------------------------------------- landmarks
// Each landmark clears its site (lots overlapping it are not generated) and builds its own massing.
struct Site { Rect r; };

void empireState(City& k) {             // W 34th St at 5th Ave (33rd-34th), 381 m roof, 443 m mast
    const double u = -75, v = stV(33.5);
    const Col c = pal::limestone * 1.05;
    k.box(u, v, 0, 128, 58, 25, c);
    k.box(u, v, 25, 100, 50, 60, c);
    k.box(u, v, 85, 72, 44, 235, c);                       // shaft to the 86th floor
    k.box(u, v, 85, 82, 30, 180, c);                       // wings that read as the shaft's buttresses
    k.box(u, v, 320, 46, 32, 12, c);
    k.box(u, v, 332, 32, 24, 12, c);
    k.box(u, v, 344, 22, 18, 14, c * 1.1);
    k.cyl(u, v, 358, 13, 23, pal::steel * 0.85, true, 0.4, 0.5);   // mooring mast
    k.cyl(u, v, 381, 3, 18, pal::steel, true, 0.4, 0.6);
    k.cyl(u, v, 399, 1.0, 44, pal::steel, true, 0.4, 0.6);        // antenna
}
void chrysler(City& k) {                // Lexington Ave at 42nd, 319 m spire
    const double u = 450, v = stV(42.5);
    const Col c = pal::whiteStone;
    k.box(u, v, 0, 60, 60, 60, c);
    k.box(u, v, 60, 50, 50, 45, c);
    k.box(u, v, 105, 40, 40, 110, c);
    for (int i = 0; i < 4; ++i) k.box(u, v, 105 + 30 * i, 44, 8, 3, pal::steel * 0.5, Pat::None, false);   // dark bands
    double dia = 34, y = 215;
    for (int i = 0; i < 6; ++i) {                          // terraced stainless crown
        k.cyl(u, v, y, dia, 9, pal::steel, true, 0.25, 0.85);
        y += 9; dia *= 0.8;
    }
    k.cone(u, v, y, dia * 1.2, 319 - y, pal::steel, true, 0.25, 0.9);
}
void oneVanderbilt(City& k) {           // Madison/Vanderbilt at 42nd, 427 m with spire
    const double u = 200, v = stV(42.5);
    const double t[][3] = {{70, 58, 0}, {62, 52, 120}, {54, 46, 230}, {42, 36, 320}, {30, 26, 380}};
    for (int i = 0; i < 5; ++i) {
        const double y0 = t[i][2], y1 = i < 4 ? t[i + 1][2] : 405;
        k.box(u + i * 1.5, v + i * 1.5, y0, t[i][0], t[i][1], y1 - y0, pal::glassSilver, Pat::Glass, true, 0.25);
    }
    k.box(u + 7, v + 7, 405, 18, 15, 8, pal::glassDark, Pat::None);
    k.cyl(u + 7, v + 7, 413, 2, 14, pal::steel, true, 0.4, 0.6);
}
void grandCentral(City& k) {            // Grand Central Terminal (42nd-44th over Park Ave) + MetLife behind it
    const double u = 290, v = stV(43);
    k.box(u, v, 0, 135, 125, 26, pal::limestone * 1.1);
    k.box(u, v + 5, 26, 80, 70, 12, pal::limestone);
    k.box(u, v + 5, 38, 76, 66, 3, pal::copper, Pat::None);           // verdigris roof
    k.cyl(u, stV(42) + 4, 24, 4, 4, pal::copper, false);               // clock / sculpture group
    k.box(u, stV(42) + 10, 26, 30, 4, 14, pal::limestone * 1.15, Pat::None);
    const double mv = stV(44.5);                                       // MetLife (Pan Am) building, 246 m
    k.box(u, mv, 0, 110, 60, 30, pal::concrete * 1.2);
    k.box(u, mv, 30, 90, 40, 210, pal::concrete * 1.15, Pat::Windows);
    k.box(u, mv, 240, 70, 30, 6, pal::concrete, Pat::None);
}
void thirtyRock(City& k) {              // 30 Rockefeller Plaza (49th-50th), plaza and the low buildings on 5th Ave
    const double v = stV(49.5);
    const double tiers[][3] = {{-190, 120, 0}, {-185, 100, 70}, {-180, 85, 160}, {-175, 65, 205}};   // centre u, length, base
    for (int i = 0; i < 4; ++i) {
        const double y1 = i < 3 ? tiers[i + 1][2] : 259;
        k.box(tiers[i][0], v, tiers[i][2], tiers[i][1], i == 0 ? 50 : 32, y1 - tiers[i][2], pal::limestone, Pat::Windows);
    }
    k.box(-175, v, 259, 40, 20, 6, pal::limestone * 0.9, Pat::None);
    k.slab(-70, v, 70, 60, 0.2, pal::plaza);                            // Rockefeller Plaza / rink
    k.box(-70, v, -0.5, 30, 20, 0.6, {0.75, 0.8, 0.85}, Pat::None, false, 0.1);   // the rink
    k.box(-40, stV(49) + 15, 0, 70, 28, 28, pal::limestone);            // La Maison Francaise / British Empire Bldg
    k.box(-40, stV(50) - 15, 0, 70, 28, 28, pal::limestone);
    k.box(-90, stV(51) - 30, 0, 110, 55, 156, pal::limestone, Pat::Windows);   // International Building (50th-51st)
}
void park432(City& k) {                 // 432 Park Ave (56th-57th), 426 m, 28.5 m square
    const double u = 300, v = stV(56.6);
    const double sq = 28.5;
    double y = 0;
    for (int i = 0; i < 6; ++i) {                                      // open mechanical floors every ~12 storeys
        const double seg = i < 5 ? 68 : 426 - y;
        k.box(u, v, y, sq, sq, seg - 6, {0.74, 0.74, 0.71}, Pat::Windows, true, 0.5);
        k.box(u, v, y + seg - 6, sq - 2, sq - 2, 6, pal::glassDark, Pat::None);
        y += seg;
    }
}
void billionairesRow(City& k) {
    // Central Park Tower (472 m), One57 (306 m), 111 W 57th (435 m, very slender), 220 CPS (290 m), 53W53 (320 m)
    {   const double u = -690, v = stV(57.55);
        k.box(u, v, 0, 60, 45, 30, pal::granite);
        k.box(u, v, 30, 46, 34, 270, pal::glassSilver, Pat::Glass, true, 0.25);
        k.box(u + 6, v, 300, 34, 34, 172, pal::glassSilver, Pat::Glass, true, 0.25);
        k.box(u + 6, v, 472, 24, 24, 6, pal::glassDark, Pat::None); }
    {   const double u = -455, v = stV(57.5);
        k.box(u, v, 0, 42, 50, 90, pal::glassBlue, Pat::Glass, true, 0.25);
        k.box(u, v + 4, 90, 36, 40, 120, pal::glassBlue, Pat::Glass, true, 0.25);
        k.box(u, v + 8, 210, 30, 30, 96, pal::glassBlue * 0.9, Pat::Glass, true, 0.25); }
    {   const double u = -335, v = stV(57.5);
        k.box(u, v, 0, 24, 60, 60, pal::terracotta, Pat::Windows);
        double y = 60, dp = 60;
        for (int i = 0; i < 6; ++i) { const double h = i < 5 ? 70 : 435 - y; k.box(u, v + (60 - dp) * 0.5, y, 18, dp, h, pal::terracotta * 1.05, Pat::Windows, true, 0.6); y += h; dp -= 8; } }
    {   const double u = -720, v = stV(58.6);
        k.box(u, v, 0, 50, 40, 120, pal::limestone * 1.1, Pat::Windows);
        k.box(u, v, 120, 36, 30, 150, pal::limestone * 1.1, Pat::Windows);
        k.box(u, v, 270, 26, 22, 20, pal::limestone, Pat::Windows); }
    {   const double u = -190, v = stV(53.6);
        double y = 0, w = 30, dp = 40;
        for (int i = 0; i < 6; ++i) { const double h = i < 5 ? 55 : 320 - y; k.box(u, v, y, w, dp, h, pal::glassDark, Pat::Glass, true, 0.3); y += h; w *= 0.85; dp *= 0.85; }
        k.cone(u, v, 320, w, 10, pal::glassDark); }
}
void midtownMore(City& k) {
    {   const double u = -235, v = stV(42.5);                         // Bank of America Tower, 366 m with spire
        k.box(u, v, 0, 75, 60, 40, pal::glassSilver * 0.9, Pat::Glass, true, 0.25);
        double y = 40, w = 62, dp = 52;
        for (int i = 0; i < 4; ++i) { const double h = i < 3 ? 70 : 290 - y; k.box(u + i * 2, v + i * 2, y, w, dp, h, pal::glassSilver, Pat::Glass, true, 0.2); y += h; w *= 0.85; dp *= 0.85; }
        k.cyl(u + 8, v + 8, 290, 2.5, 76, pal::steel, true, 0.4, 0.6); }
    {   // Bryant Park (40th-42nd, 6th Ave half) and the New York Public Library (5th Ave half)
        k.slab(-185, stV(41), 160, 140, 0.24, pal::lawn);
        for (double du = -230; du <= -140; du += 45) for (double dv : {stV(40) + 25, stV(42) - 25}) k.treeStroke(du, dv, 22, 120, 1);
        k.box(-60, stV(41), 0, 100, 120, 28, pal::whiteStone, Pat::Windows);
        k.box(-60, stV(41), 28, 70, 90, 6, pal::whiteStone * 0.85, Pat::None); }
    {   // St Patrick's Cathedral (5th Ave, 50th-51st): nave, transept, twin spires
        const double v = stV(50.5);
        k.box(70, v, 0, 100, 30, 33, {0.66, 0.64, 0.59}, Pat::None);
        k.box(80, v, 0, 18, 56, 33, {0.66, 0.64, 0.59}, Pat::None);
        k.box(70, v, 33, 100, 14, 6, pal::granite * 1.4, Pat::None);
        for (double dv : {-11.0, 11.0}) { k.box(25, v + dv, 0, 11, 11, 50, {0.66, 0.64, 0.59}, Pat::None); k.cone(25, v + dv, 50, 11, 50, {0.62, 0.6, 0.55}); } }
    {   // Plaza Hotel (5th Ave, 58th-59th) with its copper mansard; GM Building opposite
        k.box(-70, stV(58.6), 0, 110, 55, 70, {0.70, 0.67, 0.60}, Pat::Windows);
        k.box(-70, stV(58.6), 70, 100, 45, 8, pal::copper, Pat::None);
        k.box(60, stV(58.5), 0, 100, 62, 20, pal::whiteStone);
        k.box(60, stV(58.5), 20, 50, 36, 195, {0.74, 0.74, 0.72}, Pat::Windows, true, 0.5); }
    {   // Madison Square Garden (31st-33rd, 7th-8th) and One Penn Plaza
        k.cyl(-700, stV(32), 0, 130, 46, pal::concrete * 1.1, true, 0.8, 0, Pat::Windows);
        k.cyl(-700, stV(32), 46, 136, 2, pal::concrete * 0.8, false);
        k.box(-780, stV(33.6), 0, 60, 45, 229, pal::glassDark, Pat::Glass, true, 0.25); }
    {   // Macy's Herald Square (34th-35th, 6th-7th)
        k.box(-420, stV(34.5), 0, 200, 62, 46, {0.48, 0.40, 0.33}, Pat::Windows);
        k.box(-330, stV(34) + 2, 8, 12, 0.6, 6, {0.25, 0.03, 0.03}, Pat::None, false, 0.5, 0, 4.0); }
    {   // Hudson Yards (30th-33rd, 10th-11th): 30 HY (387 m, The Edge), 10 HY, 35 HY and the Vessel
        k.box(-1440, stV(32.5), 0, 70, 70, 300, pal::glassBlue, Pat::Glass, true, 0.2);
        k.box(-1440, stV(32.6), 300, 54, 54, 87, pal::glassBlue, Pat::Glass, true, 0.2);
        k.box(-1475, stV(32.6), 335, 20, 30, 3, pal::steel, Pat::None, true, 0.3, 0.7);        // the Edge
        k.box(-1520, stV(31.3), 0, 60, 50, 268, pal::glassSilver, Pat::Glass, true, 0.2);
        k.box(-1620, stV(33.2), 0, 50, 40, 308, pal::glassBlue * 1.1, Pat::Glass, true, 0.2);
        k.slab(-1560, stV(32.2), 120, 100, 0.25, pal::plaza);
        k.cyl(-1560, stV(32.2), 0, 18, 8, {0.45, 0.28, 0.16}, true, 0.4, 0.6);        // the Vessel (widening upwards)
        k.cyl(-1560, stV(32.2), 8, 28, 14, {0.45, 0.28, 0.16}, true, 0.4, 0.6);
        k.cyl(-1560, stV(32.2), 22, 40, 24, {0.45, 0.28, 0.16}, true, 0.4, 0.6); }
    {   // United Nations (1st Ave, 42nd-48th): Secretariat slab and General Assembly
        k.box(1050, stV(43.5), 0, 22, 88, 155, pal::glassGreen, Pat::Glass, true, 0.2);
        k.box(1050, stV(43.5) - 45, 0, 23, 2, 155, pal::whiteStone, Pat::None);
        k.box(1050, stV(43.5) + 45, 0, 23, 2, 155, pal::whiteStone, Pat::None);
        k.box(1060, stV(46), 0, 40, 100, 28, pal::whiteStone);
        k.cyl(1060, stV(46), 28, 22, 6, pal::whiteStone * 0.9, false);
        k.slab(1050, stV(45), 120, 480, 0.24, pal::lawn); }
    {   // Time Warner (Deutsche Bank) Center twin towers at Columbus Circle, and the circle's column
        for (double dv : {-25.0, 25.0}) {
            k.box(-905, stV(59.6) + dv, 0, 90, 46, 50, pal::glassBlue, Pat::Glass, true, 0.25);
            k.box(-925, stV(59.6) + dv, 50, 40, 30, 179, pal::glassBlue, Pat::Glass, true, 0.25);
        }
        k.cyl(-840, stV(59), 0, 110, 0.25, pal::plaza, false);
        k.cyl(-840, stV(59), 0, 3, 21, pal::whiteStone);
        k.box(-840, stV(59), 21, 1.5, 1.5, 3, pal::whiteStone * 0.9, Pat::None); }
}

/// Times Square bow tie: plaza on Broadway/7th 42nd-47th, One Times Square at the tip, billboards on the facades.
void timesSquareSigns(City& k, double u, double v, double w, double dp, double h) {
    static const Col colours[] = {{1.0, 0.15, 0.1}, {0.1, 0.4, 1.0}, {1.0, 0.8, 0.1}, {0.9, 0.9, 1.0}, {0.1, 1.0, 0.4}, {1.0, 0.2, 0.7}, {1.0, 0.5, 0.05}};
    const int n = 1 + int(k.rng.next() * 3);
    for (int i = 0; i < n; ++i) {
        const int face = int(k.rng.next() * 4);
        const double sw = std::min(face < 2 ? dp : w, k.rng.range(10, 28)) * 0.9, sh = k.rng.range(6, 22), y = k.rng.range(6, std::max(8.0, std::min(h - sh, 70.0)));
        const Col col = colours[int(k.rng.next() * 7) % 7] * 0.25;   // dark screen, saturated glow (glow = albedo x emissive)
        const double e = k.rng.range(3.0, 5.0);
        if (face == 0) k.box(u - w * 0.5 - 0.4, v, y, 0.6, sw, sh, col, Pat::None, false, 0.4, 0, e);
        else if (face == 1) k.box(u + w * 0.5 + 0.4, v, y, 0.6, sw, sh, col, Pat::None, false, 0.4, 0, e);
        else if (face == 2) k.box(u, v - dp * 0.5 - 0.4, y, sw, 0.6, sh, col, Pat::None, false, 0.4, 0, e);
        else k.box(u, v + dp * 0.5 + 0.4, y, sw, 0.6, sh, col, Pat::None, false, 0.4, 0, e);
    }
}
bool inTimesSquare(double u, double v) { return v > stV(41.6) && v < stV(48) && std::fabs(u - broadwayU(v) * 0.5 - (-560) * 0.5) < 170; }

// ---------------------------------------------------------------------- the waterfronts
void hudsonPiers(City& k) {
    for (double n : {40.0, 42.0, 44.0, 49.0, 51.0, 53.0, 55.0}) {   // Circle Line piers, cruise terminal 88/90/92
        const double v = stV(n) + 20, len = n >= 48 ? 330 : 240, wd = n >= 48 ? 42 : 26;
        k.box(kWestShore - len * 0.5, v, -1.0, len, wd, 2.6, pal::concrete * 0.9, Pat::None, true, 0.9);
        if (n >= 48) k.box(kWestShore - len * 0.5 - 10, v, 1.6, len - 30, wd - 8, 14, {0.55, 0.56, 0.58}, Pat::None, true, 0.6, 0.3);
    }
    // Pier 86 and the USS Intrepid alongside it (46th St)
    const double v = stV(46) + 20;
    k.box(kWestShore - 130, v, -1.0, 260, 30, 2.6, pal::concrete * 0.9, Pat::None);
    const double sv = v + 36;
    k.box(kWestShore - 150, sv, -6, 250, 30, 19, pal::navyGrey, Pat::None, true, 0.7, 0.2);       // hull
    k.box(kWestShore - 150, sv, 13, 262, 40, 1.5, pal::navyGrey * 0.7, Pat::None, true, 0.8);    // flight deck
    k.box(kWestShore - 120, sv + 17, 14.5, 35, 7, 16, pal::navyGrey, Pat::None);                 // island
    k.cyl(kWestShore - 118, sv + 17, 30.5, 2.5, 12, pal::navyGrey * 0.8);
    k.box(kWestShore - 230, sv - 6, 14.5, 45, 22, 12, {0.85, 0.85, 0.85}, Pat::None, true, 0.6);  // shuttle pavilion
    // Hudson River Park: a green promenade along the bulkhead with a row of trees
    k.slab(kWestShore + 40, stV(63), 80, stV(96) - stV(30), 0.2, pal::lawn);
    for (double n = 31; n < 95; n += 1.0) k.treeStroke(kWestShore + 62, stV(n), 14, 90, n > 60 ? 1 : 2);   // clear of the carved river bed
}

void newJersey(City& k) {
    // Port Imperial / Weehawken waterfront, then the Palisades cliff with a plateau of low-rise on top.
    const double shore = -3050;
    k.slab(shore - 80, stV(63), 160, 6600, 0.2, pal::concrete * 0.8);
    for (double n = 28; n < 100; n += 3) {
        const double h = k.rng.range(12, 40);
        k.building({shore - 140, shore - 20, stV(n), stV(n) + k.rng.range(80, 200)}, h, h > 25 ? 1 : 0,
                   k.rng.chance(0.5) ? pal::buffBrick : pal::glassBlue, false);
    }
    k.box(shore - 600, stV(63), 0, 800, 6600, 55, {0.17, 0.20, 0.11}, Pat::None, true, 1.0);   // the Palisades plateau
    k.box(shore - 202, stV(63), 0, 4, 6600, 54, {0.25, 0.22, 0.18}, Pat::None, true, 1.0);     // cliff face
    for (int i = 0; i < 160; ++i) {
        const double u = k.rng.range(shore - 960, shore - 260), v = k.rng.range(stV(26), stV(100));
        const double w = k.rng.range(15, 40), dp = k.rng.range(15, 50), h = k.rng.range(8, 30) * (k.rng.chance(0.08) ? 3 : 1);
        k.building({u - w / 2, u + w / 2, v - dp / 2, v + dp / 2}, h, h > 25 ? 1 : 0, k.rng.chance(0.5) ? pal::redBrick : pal::buffBrick, false);
    }
}

void queensSide(City& k) {
    // Roosevelt Island (between the two East River channels) and Long Island City beyond.
    const double ri0 = 1360, ri1 = 1600, q0 = 1800;
    k.slab(0.5 * (ri0 + ri1), stV(60), ri1 - ri0, stV(90) - stV(30), 0.25, pal::lawn);
    for (double n = 54; n < 88; n += 2.2) {
        if (n > 58 && n < 61) continue;
        const double h = k.rng.range(20, 60);
        k.building({ri0 + 40, ri0 + 120, stV(n), stV(n) + 70}, h, 1, k.rng.chance(0.6) ? pal::redBrick : pal::buffBrick, false);
    }
    k.slab(0.5 * (q0 + 3400), stV(63), 3400 - q0, 6600, 0.2, pal::concrete * 0.7);
    for (double u = q0 + 60; u < 3300; u += 110) for (double n = 27; n < 99; n += 1.6) {
        if (k.rng.chance(0.25)) continue;
        const double v = stV(n);
        const double core = gauss(u, v, 2450, 44, 350, 4), shoreG = (u < q0 + 200 && n > 45 && n < 51) ? 1.0 : 0.0;
        double h = k.rng.range(8, 22) + core * k.rng.range(40, 160) + shoreG * k.rng.range(80, 140);
        const int style = h > 70 ? 2 : h > 22 ? 1 : 0;
        k.building({u, u + k.rng.range(50, 95), v, v + k.rng.range(50, 100)}, h, style, style == 2 ? pal::glassBlue : (k.rng.chance(0.5) ? pal::redBrick : pal::concrete), false);
    }
    k.box(2450, stV(44), 0, 45, 45, 200, pal::glassGreen, Pat::Glass, true, 0.2);   // One Court Square (Citigroup)
    k.box(q0 + 20, stV(47), 4, 1.0, 40, 10, {0.25, 0.02, 0.015}, Pat::None, false, 0.5, 0, 4.0);   // the Pepsi-Cola sign
    // Queensboro Bridge (59th-60th St): towers, deck and the cantilever truss
    const double v = stV(59.5);
    const Col steel{0.30, 0.34, 0.33};
    k.box(1500, v, 30, 2200, 26, 3, steel * 0.8, Pat::None, true, 0.7, 0.3);
    for (double u : {kEastShore - 20.0, ri0 + 20, ri1 - 20, q0 + 20}) {
        k.box(u, v, 0, 18, 36, 105, steel, Pat::None, true, 0.6, 0.3);
        k.cone(u, v - 14, 105, 6, 12, steel); k.cone(u, v + 14, 105, 6, 12, steel);
    }
    for (double u = kEastShore - 200; u < q0 + 200; u += 40) {
        const double towerD = std::min({std::fabs(u - kEastShore), std::fabs(u - ri0), std::fabs(u - ri1), std::fabs(u - q0)});
        const double top = 33 + 60 * std::exp(-towerD * towerD / (2 * 140.0 * 140.0)) + 12;
        for (double dv : {-12.0, 12.0}) k.box(u, v + dv, 33, 1.5, 1.5, top - 33, steel, Pat::None, false, 0.6, 0.3);
        k.box(u + 20, v - 12, top - 2, 41, 1.8, 2, steel, Pat::None, false, 0.6, 0.3);
        k.box(u + 20, v + 12, top - 2, 41, 1.8, 2, steel, Pat::None, false, 0.6, 0.3);
    }
}

// ---------------------------------------------------------------------- Central Park
struct ParkFeatures { Rect park, reservoir, lake, pond, greatLawn, sheepMeadow; };
ParkFeatures centralPark(City& k) {
    ParkFeatures f;
    f.park = {-840 + 15, 0 - 15, stV(59) + 15, stV(96) + 9};          // CPW to 5th Ave, 59th to (here) 96th
    f.reservoir = {-640, -180, stV(86) + 10, stV(95) - 20};
    f.lake = {-620, -380, stV(72) + 20, stV(77) + 30};
    f.pond = {-200, -90, stV(59) + 40, stV(62)};
    f.greatLawn = {-560, -280, stV(80), stV(85)};
    f.sheepMeadow = {-640, -440, stV(66), stV(69)};
    const auto& p = f.park;
    k.slab(0.5 * (p.u0 + p.u1), 0.5 * (p.v0 + p.v1), p.u1 - p.u0, p.v1 - p.v0, 0.12, pal::grass, 1.0);
    k.slab(0.5 * (f.greatLawn.u0 + f.greatLawn.u1), 0.5 * (f.greatLawn.v0 + f.greatLawn.v1), f.greatLawn.u1 - f.greatLawn.u0, f.greatLawn.v1 - f.greatLawn.v0, 0.16, pal::lawn, 1.0);
    k.slab(0.5 * (f.sheepMeadow.u0 + f.sheepMeadow.u1), 0.5 * (f.sheepMeadow.v0 + f.sheepMeadow.v1), f.sheepMeadow.u1 - f.sheepMeadow.u0, f.sheepMeadow.v1 - f.sheepMeadow.v0, 0.16, pal::lawn, 1.0);
    for (double n : {65.0, 79.0, 85.5}) k.slab(0.5 * (p.u0 + p.u1), stV(n), p.u1 - p.u0, 12, 0.18, pal::asphalt);   // transverse roads
    k.slab(-420, stV(78), 12, stV(96) - stV(60), 0.17, pal::sidewalk * 0.9);   // the drive / main path
    // Reservoir (octagon-ish), the Lake (irregular) and the Pond
    const auto& r = f.reservoir;
    const double cu = 0.5 * (r.u0 + r.u1), cv = 0.5 * (r.v0 + r.v1), ru = 0.5 * (r.u1 - r.u0), rv = 0.5 * (r.v1 - r.v0);
    std::vector<std::vector<double>> oct;
    for (int i = 0; i < 16; ++i) { const double a = 2 * kPi * i / 16; oct.push_back({cu + ru * std::cos(a) * (0.92 + 0.08 * std::cos(3 * a)), cv + rv * std::sin(a)}); }
    k.lake("reservoir", oct);
    k.slab(cu, cv, 2 * ru + 30, 2 * rv + 30, 0.15, pal::sidewalk * 0.9);       // the running track around it
    const auto& l = f.lake;
    k.lake("the-lake", {{l.u0, l.v0 + 60}, {l.u0 + 90, l.v0}, {l.u1, l.v0 + 40}, {l.u1 - 30, l.v1 - 80}, {l.u1, l.v1}, {l.u0 + 120, l.v1 - 30}, {l.u0 + 20, l.v1 - 10}});
    k.lake("the-pond", {{f.pond.u0, f.pond.v0}, {f.pond.u1, f.pond.v0 + 20}, {f.pond.u1 - 20, f.pond.v1}, {f.pond.u0 + 10, f.pond.v1 - 30}});
    // Trees: overlapping tree strokes on a grid, skipping water, lawns and roads.
    auto clear = [&](double u, double v, double rad) {
        for (const Rect* z : {&f.reservoir, &f.lake, &f.pond, &f.greatLawn, &f.sheepMeadow})
            if (Rect{z->u0 - rad - 45, z->u1 + rad + 45, z->v0 - rad - 45, z->v1 + rad + 45}.contains(u, v)) return false;   // lake beds are carved ~1 cell wider
        for (double n : {65.0, 79.0, 85.5}) if (std::fabs(v - stV(n)) < rad + 8) return false;
        return u - rad > p.u0 + 4 && u + rad < p.u1 - 4 && v - rad > p.v0 + 4 && v + rad < p.v1 - 4;
    };
    int i = 0;
    for (double v = p.v0 + 40; v < p.v1 - 30; v += 75)
        for (double u = p.u0 + 40; u < p.u1 - 30; u += 75) {
            const double ju = u + k.rng.range(-15, 15), jv = v + k.rng.range(-15, 15), rad = k.rng.range(30, 42);
            if (!clear(ju, jv, rad)) continue;
            k.treeStroke(ju, jv, rad, k.rng.range(60, 130), (i++ % 3 == 0) ? 2 : 1);
        }
    return f;
}

// ---------------------------------------------------------------------- the blocks
struct District { double tall; bool residential; bool hellsKitchen; };
District district(double u, double v) {
    const double n = v / kStreet + 34;
    District d{};
    d.tall = std::max({gauss(u, v, -380, 48, 420, 8),          // Midtown core (Times Sq - Rockefeller)
                       0.95 * gauss(u, v, 250, 49, 260, 9),    // Grand Central / Park Ave corridor
                       0.85 * gauss(u, v, -280, 50, 110, 8),   // 6th Ave towers
                       0.75 * gauss(u, v, -1450, 32, 280, 3),  // Hudson Yards
                       0.6 * gauss(u, v, 450, 38, 450, 5),     // Murray Hill / Kips Bay
                       0.55 * gauss(u, v, -600, 36, 300, 3)}); // Garment district
    d.residential = n > 59.5;
    d.hellsKitchen = !d.residential && u < -880 && n > 41 && n < 59;
    return d;
}

void blocks(City& k, const std::vector<Rect>& sites, const ParkFeatures& park, int& lotCount) {
    auto blocked = [&](const Rect& r) {
        for (auto& s : sites) if (s.overlaps(r)) return true;
        if (park.park.overlaps(r)) return true;
        // Broadway: a 25 m strip along its centre line (it cuts the blocks diagonally)
        const double vb = 0.5 * (r.v0 + r.v1);
        if (vb < stV(71)) {
            const double bu0 = std::min(broadwayU(r.v0), broadwayU(r.v1)) - 13, bu1 = std::max(broadwayU(r.v0), broadwayU(r.v1)) + 13;
            if (r.u0 < bu1 && r.u1 > bu0) return true;
        }
        return false;
    };
    // the asphalt under the whole island grid
    k.slab(0.5 * (kWestShore + kEastShore), 0.5 * (stV(kFirstSt - 1) + stV(kLastSt + 1)), kEastShore - kWestShore,
           stV(kLastSt + 1) - stV(kFirstSt - 1), 0.04, pal::asphalt, 0.9);
    // west of 11th Ave: 12th Ave / West Side Highway and a strip of low warehouses; east of 1st: FDR Drive
    for (int a = -1; a < kAveCount; ++a) {
        const double uA = a < 0 ? kWestShore + 80 : kAves[a].u + kAves[a].width * 0.5;
        const double uB = a + 1 < kAveCount ? kAves[a + 1].u - kAves[a + 1].width * 0.5 : kEastShore - 25;
        if (uB - uA < 20) continue;
        for (int n = int(kFirstSt); n < int(kLastSt); ++n) {
            const double vA = stV(n) + streetWidth(n) * 0.5, vB = stV(n + 1) - streetWidth(n + 1) * 0.5;
            const Rect blk{uA, uB, vA, vB};
            if (park.park.overlaps(blk)) continue;
            const double bu = 0.5 * (uA + uB), bv = 0.5 * (vA + vB);
            // Times Square plaza: the bow tie between Broadway and 7th from 42nd to 47th is pedestrian
            k.slab(bu, bv, uB - uA, vB - vA, 0.18, inTimesSquare(bu, bv) ? pal::plaza : pal::sidewalk);
            const Rect in{uA + 4, uB - 4, vA + 4, vB - 4};
            const District dist = district(bu, bv);
            const bool uptown = dist.residential;
            // lots: avenue-end lots run through the block; the middle splits into north and south rows
            std::vector<std::pair<Rect, bool>> lots;   // rect, through-lot (avenue frontage)
            const double len = in.u1 - in.u0;
            double endW = len < 70 ? len : k.rng.range(uptown ? 25 : 28, uptown ? 40 : 55);
            if (len < 70) { lots.push_back({in, true}); }
            else {
                double eastW = k.rng.range(uptown ? 25 : 28, uptown ? 40 : 55);
                if (endW + eastW > len - 12) endW = eastW = len * 0.5;
                lots.push_back({{in.u0, in.u0 + endW, in.v0, in.v1}, true});
                lots.push_back({{in.u1 - eastW, in.u1, in.v0, in.v1}, true});
                const double m0 = in.u0 + endW, m1 = in.u1 - eastW, vm = 0.5 * (in.v0 + in.v1);
                for (int row = 0; row < 2 && m1 - m0 > 4; ++row) {
                    const double r0 = row == 0 ? in.v0 : vm, r1 = row == 0 ? vm : in.v1;
                    double u = m0;
                    while (u < m1 - 4) {
                        double w = uptown ? k.rng.range(10, 20) : (dist.hellsKitchen ? k.rng.range(10, 20) : k.rng.range(14, 38));
                        if (m1 - (u + w) < 8) w = m1 - u;
                        lots.push_back({{u, u + w, r0, r1}, false});
                        u += w;
                    }
                }
            }
            for (auto& [lot, through] : lots) {
                if (blocked(lot)) continue;
                ++lotCount;
                const double lu = 0.5 * (lot.u0 + lot.u1), lv = 0.5 * (lot.v0 + lot.v1);
                const double w = lot.u1 - lot.u0, dp = lot.v1 - lot.v0;
                const District dd = district(lu, lv);
                double h; int style; Col col;
                const double r = k.rng.next();
                if (dd.residential) {
                    const bool frontage = through || lot.u0 < -840 + 60 || lot.u1 > -60;   // avenues, CPW, 5th Ave
                    if (frontage) { h = k.rng.range(40, 75) * (k.rng.chance(0.06) ? 2.2 : 1); style = h > 110 ? 2 : 1; }
                    else if (r < 0.7) { h = k.rng.range(13, 20); style = 0; }
                    else { h = k.rng.range(30, 55); style = 1; }
                    col = style == 0 ? (k.rng.chance(0.6) ? pal::brownstone : pal::redBrick) * k.rng.range(0.85, 1.15)
                        : style == 2 ? pal::glassBlue : (k.rng.chance(0.5) ? pal::limestone : pal::buffBrick) * k.rng.range(0.85, 1.1);
                } else if (dd.hellsKitchen) {
                    h = through ? k.rng.range(18, 45) : k.rng.range(14, 24);
                    if (through && k.rng.chance(0.15)) h = k.rng.range(60, 140);
                    style = h > 60 ? 2 : h > 26 ? 1 : 0;
                    col = style == 2 ? (k.rng.chance(0.5) ? pal::glassBlue : pal::glassSilver) : (k.rng.chance(0.6) ? pal::redBrick : pal::darkBrick) * k.rng.range(0.85, 1.15);
                } else {
                    const double t = dd.tall;
                    h = through ? 28 + 45 * r + t * (70 + 230 * r * r) : 16 + 30 * r + t * (25 + 120 * r * r);
                    h = std::min(h, 6.5 * std::min(w, dp) + 30);
                    if (h < 26) style = 0;
                    else if (h < 85) style = 1;
                    else style = k.rng.chance(0.55) ? 2 : 3;
                    if (style == 0) col = (k.rng.chance(0.5) ? pal::redBrick : pal::brownstone) * k.rng.range(0.85, 1.15);
                    else if (style == 1) col = std::array<Col, 4>{pal::buffBrick, pal::limestone, pal::redBrick, pal::whiteStone}[std::size_t(k.rng.next() * 3.999)] * k.rng.range(0.85, 1.1);
                    else if (style == 2) col = std::array<Col, 4>{pal::glassBlue, pal::glassGreen, pal::glassDark, pal::glassSilver}[std::size_t(k.rng.next() * 3.999)];
                    else col = std::array<Col, 3>{pal::deco, pal::limestone, pal::buffBrick}[std::size_t(k.rng.next() * 2.999)] * k.rng.range(0.9, 1.1);
                }
                // a little variety in the street wall
                const double fs = style >= 2 ? 0 : k.rng.range(0, 1.2);
                Rect b = lot;
                if (lot.v0 <= in.v0 + 0.1) b.v0 += fs; else if (lot.v1 >= in.v1 - 0.1) b.v1 -= fs;
                k.building(b, h, style, col);
                if (inTimesSquare(lu, lv)) timesSquareSigns(k, lu, lv, b.u1 - b.u0, b.v1 - b.v0, h);
            }
        }
    }
}
} // namespace

Vec3d manhattanPoint(double u, double v, double y) {
    WorldDocument scratch;
    return City(scratch).W(u, v, G + y);
}

WorldDocument manhattanMidtown() {
    WorldDocument d;
    d.name = "Manhattan (Midtown)";
    d.terrain.kind = TerrainKind::Flat;
    d.terrain.params.set("level", Value::number(G));
    d.environment.timeOfDayHours = 15.5;
    d.environment.sunAzimuthDeg = 215;
    d.environment.fogDensity = 0.6;

    City k(d);
    // landmarks first; their sites keep the lot generator away
    std::vector<Rect> sites = {
        {-145, -10, stV(33), stV(34)},                 // Empire State
        {400, 500, stV(42), stV(43)},                  // Chrysler
        {150, 245, stV(42), stV(43)},                  // One Vanderbilt
        {220, 360, stV(42), stV(45)},                  // Grand Central + MetLife
        {-270, -15, stV(49), stV(51)},                 // Rockefeller Center
        {270, 330, stV(56), stV(57)},                  // 432 Park
        {-730, -650, stV(57), stV(58)}, {-480, -430, stV(57), stV(58)}, {-350, -320, stV(57), stV(58)},
        {-750, -690, stV(58), stV(59)}, {-210, -170, stV(53), stV(54)},
        {-275, -195, stV(42), stV(43)},                // Bank of America Tower
        {-270, -10, stV(40), stV(42)},                 // Bryant Park + NYPL
        {15, 125, stV(50), stV(51)},                   // St Patrick's
        {-130, -10, stV(58), stV(59)}, {10, 125, stV(58), stV(59)},   // Plaza Hotel, GM Building
        {-830, -570, stV(31), stV(33)}, {-830, -750, stV(33), stV(34)},   // MSG, One Penn Plaza
        {-545, -290, stV(34), stV(35)},                // Macy's
        {-1670, -1410, stV(30), stV(34)},              // Hudson Yards
        {995, 1110, stV(42), stV(48)},                 // United Nations
        {-990, -850, stV(58), stV(61)},                // Time Warner Center
    };
    empireState(k); chrysler(k); oneVanderbilt(k); grandCentral(k); thirtyRock(k); park432(k); billionairesRow(k); midtownMore(k);
    // One Times Square at the bow tie's south tip, wrapped in signs
    {   const double u = -470, v = stV(42.5);
        k.box(u, v, 0, 20, 40, 111, pal::limestone, Pat::Windows);
        timesSquareSigns(k, u, v, 20, 40, 111); timesSquareSigns(k, u, v, 20, 40, 111); timesSquareSigns(k, u, v, 20, 40, 111);
        sites.push_back({-485, -455, stV(42), stV(43)}); }
    const ParkFeatures park = centralPark(k);
    int lots = 0;
    blocks(k, sites, park, lots);
    hudsonPiers(k);
    newJersey(k);
    queensSide(k);

    // Rivers: Hudson (12th Ave to New Jersey) and the two East River channels around Roosevelt Island.
    const double v0 = stV(18), v1 = stV(110);
    k.lakeRect("hudson", {-3050, kWestShore, v0, v1});
    k.lakeRect("east-river-west", {kEastShore, 1360, v0, v1});
    k.lakeRect("east-river-east", {1600, 1800, v0, v1});
    k.slab(0.5 * (1360 + 1600), stV(63) + 0, 240, v1 - v0, 0.25, pal::lawn);   // the rest of Roosevelt Island
    // bulkheads / sea walls along every shore (the water surface sits a little above the flat ground)
    for (double u : {kWestShore, kEastShore, 1360.0, 1600.0, 1800.0, -3050.0})
        k.prim("box", "ground", u, 0.5 * (v0 + v1), -9, 2.5, v1 - v0, 10.3, pal::concrete * 0.75, Pat::None, false, 0.9);

    // Trees only where the strokes put them (Central Park, Bryant Park, Hudson River Park).
    JsonObject veg;
    veg.set("enabled", Value::fromBool(true));
    veg.set("treeDensityPerHa", Value::number(0));
    veg.set("seaLevel", Value::number(G - 10));
    veg.set("grassDensity", Value::number(0));
    veg.set("strokes", k.strokes_);
    d.vegetation = veg;

    // Spawn: the south end of the Great Lawn, facing up-town (open ground for a take-off towards the Reservoir).
    // Crafts fly along their +X axis: turn +X onto the up-town axis (s, 0, -c).
    d.spawn = Transform(k.W(-420, stV(80) + 25, G + 2), Quatd::angleAxis((90.0 - 29.0) * kPi / 180.0, {0, 1, 0}));
    return d;
}
} // namespace pw::world::presets
