// OpenFOAM offline reference: case export, run (subprocess), per-part force import. See pw/flow/openfoam.h.
#include "pw/flow/openfoam.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include "pw/aero.h"
#include "pw/craft/document.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/full_aero.h"

namespace pw::flow::openfoam {
namespace fs = std::filesystem;

namespace {

std::string header(const char* cls, const char* object, const char* location = nullptr) {
    std::ostringstream s;
    s << "/*--------------------------------*- C++ -*----------------------------------*\\\n"
         "  Written by Plane World (pwcli --openfoam-export). OpenFOAM reference case.\n"
         "\\*---------------------------------------------------------------------------*/\n"
         "FoamFile\n{\n    version     2.0;\n    format      ascii;\n    class       "
      << cls << ";\n";
    if (location) s << "    location    \"" << location << "\";\n";
    s << "    object      " << object << ";\n}\n\n";
    return s.str();
}

bool writeFile(const fs::path& p, const std::string& text, std::string* err) {
    std::error_code ec;
    fs::create_directories(p.parent_path(), ec);
    std::ofstream f(p, std::ios::binary);
    if (!f) { if (err) *err = "cannot write " + p.string(); return false; }
    f << text;
    return bool(f);
}

std::string sanitize(const std::string& s) {
    std::string o;
    for (char c : s) o += (std::isalnum(static_cast<unsigned char>(c)) ? c : '_');
    if (o.empty()) o = "part";
    return o.substr(0, 24);
}

std::string vec(const Vec3d& v) {
    char b[128];
    std::snprintf(b, sizeof b, "(%.6g %.6g %.6g)", v.x, v.y, v.z);
    return b;
}

std::string num(double v) {
    char b[64];
    std::snprintf(b, sizeof b, "%.6g", v);
    return b;
}

struct Mesh {
    std::vector<Vec3d> pts;
    std::vector<uint32_t> idx;
};

std::string stl(const std::string& name, const Mesh& m) {
    std::ostringstream s;
    s << "solid " << name << "\n";
    char b[256];
    for (std::size_t t = 0; t + 2 < m.idx.size(); t += 3) {
        const Vec3d a = m.pts[m.idx[t]], c1 = m.pts[m.idx[t + 1]], c2 = m.pts[m.idx[t + 2]];
        Vec3d n = cross(c1 - a, c2 - a);
        const double l = length(n);
        if (l < 1e-20) continue;
        n = n / l;
        std::snprintf(b, sizeof b, "  facet normal %.6e %.6e %.6e\n    outer loop\n", n.x, n.y, n.z);
        s << b;
        for (const Vec3d& v : {a, c1, c2}) { std::snprintf(b, sizeof b, "      vertex %.7e %.7e %.7e\n", v.x, v.y, v.z); s << b; }
        s << "    endloop\n  endfacet\n";
    }
    s << "endsolid " << name << "\n";
    return s.str();
}

} // namespace

bool exportCase(const craft::CraftDocument& craft, const CaseOptions& o, const std::string& dirStr, std::vector<PartPatch>* patchesOut, std::string* error) {
    auto fail = [&](const std::string& e) { if (error) *error = e; return false; };
    const fs::path dir(dirStr);
    // posed parts: the same transforms the in-app CFD uses (CraftSim part poses), CoM at the origin
    sim::CraftSim cs;
    std::string err;
    if (!cs.load(sim::CraftSpec::fromDocument(craft), &err)) return fail("craft load: " + err);
    const Quatd q = Quatd::angleAxis(o.alphaDeg * kPi / 180, {0, 0, 1});
    cs.reset({0, o.altitude, 0}, q);
    const Vec3d com = cs.position();
    const std::vector<sim::PartPose> poses = cs.partPoses();
    const std::vector<sim::AeroPartGeometry> geo = sim::aeroParts(craft);
    std::vector<PartPatch> patches;
    std::vector<Mesh> meshes;
    Vec3d lo = Vec3d::splat(1e30), hi = Vec3d::splat(-1e30);
    for (const auto& g : geo) {
        if (g.isRotor || g.indices.size() < 3 || std::size_t(g.partIndex) >= poses.size()) continue;   // props: not meshed (throttle 0)
        Mesh m;
        const sim::PartPose& p = poses[std::size_t(g.partIndex)];
        for (const auto& v : g.positions) {
            const Vec3d w = p.position - com + p.rotation.act(Vec3d{v.x, v.y, v.z});
            m.pts.push_back(w);
            for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], w[a]); hi[a] = std::max(hi[a], w[a]); }
        }
        m.idx = g.indices;
        PartPatch pp;
        pp.partIndex = g.partIndex;
        pp.name = craft.parts[std::size_t(g.partIndex)].name;
        pp.type = g.kind;
        pp.patch = "p" + std::to_string(g.partIndex) + "_" + sanitize(pp.name);
        patches.push_back(pp);
        meshes.push_back(std::move(m));
    }
    if (patches.empty()) return fail("craft has no meshable parts");
    const double L = std::max({hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 0.05});
    // free stream: craft flies +x, so the air comes from +x
    const Atmosphere atm = sim::SimEnvironment{}.atmosphere(o.altitude);
    const double rho = atm.density, nu = aero::viscosity(atm.temperature) / std::max(rho, 1e-9);
    const Vec3d Uinf{-o.speed, 0, 0};
    const double U = std::max(o.speed, 1.0);
    // domain: inlet at +x (upstream), outlet at -x
    const Vec3d dlo{lo.x - o.downstream * L, lo.y - o.lateral * L, lo.z - o.lateral * L};
    const Vec3d dhi{hi.x + o.upstream * L, hi.y + o.lateral * L, hi.z + o.lateral * L};
    const double h0 = L / std::max(4, o.backgroundCells);
    int nc[3];
    for (int a = 0; a < 3; ++a) nc[a] = std::max(4, int(std::ceil((dhi[a] - dlo[a]) / h0)));
    const double k = 1.5 * std::pow(o.turbulenceIntensity * U, 2), nut = o.viscosityRatio * nu, omega = k / nut;
    const double endTime = o.endTime > 0 ? o.endTime : (o.steady ? 1500.0 : 10 * L / U);
    const double cellMin = h0 / double(1 << std::max(0, o.surfaceLevelMax));
    const double deltaT = o.steady ? 1.0 : 0.5 * cellMin / (1.5 * U);
    const double writeInterval = o.steady ? 500.0 : endTime / 5;
    std::ostringstream s;

    // geometry
    for (std::size_t i = 0; i < patches.size(); ++i)
        if (!writeFile(dir / "constant" / "triSurface" / (patches[i].patch + ".stl"), stl(patches[i].patch, meshes[i]), error)) return false;

    // blockMeshDict
    s.str("");
    s << header("dictionary", "blockMeshDict", "system") << "convertToMeters 1;\n\nvertices\n(\n";
    for (int c = 0; c < 8; ++c) {
        const int bx = (c == 1 || c == 2 || c == 5 || c == 6) ? 1 : 0, by = (c == 2 || c == 3 || c == 6 || c == 7) ? 1 : 0, bz = c >= 4 ? 1 : 0;
        s << "    " << vec({bx ? dhi.x : dlo.x, by ? dhi.y : dlo.y, bz ? dhi.z : dlo.z}) << "\n";
    }
    s << ");\n\nblocks\n(\n    hex (0 1 2 3 4 5 6 7) (" << nc[0] << " " << nc[1] << " " << nc[2] << ") simpleGrading (1 1 1)\n);\n\n"
      << "boundary\n(\n"
         "    inlet  { type patch; faces ((1 2 6 5)); }\n"
         "    outlet { type patch; faces ((0 4 7 3)); }\n"
         "    sides  { type patch; faces ((0 1 5 4) (3 7 6 2) (0 3 2 1) (4 5 6 7)); }\n);\n";
    if (!writeFile(dir / "system" / "blockMeshDict", s.str(), error)) return false;

    // snappyHexMeshDict
    s.str("");
    s << header("dictionary", "snappyHexMeshDict", "system")
      << "castellatedMesh true;\nsnap            true;\naddLayers       " << (o.layers > 0 ? "true" : "false") << ";\n\ngeometry\n{\n";
    for (const auto& p : patches) s << "    " << p.patch << ".stl { type triSurfaceMesh; name " << p.patch << "; }\n";
    s << "}\n\ncastellatedMeshControls\n{\n    maxLocalCells 4000000;\n    maxGlobalCells 20000000;\n    minRefinementCells 0;\n"
         "    maxLoadUnbalance 0.10;\n    nCellsBetweenLevels 3;\n    features ();\n    refinementSurfaces\n    {\n";
    for (const auto& p : patches)
        s << "        " << p.patch << " { level (" << o.surfaceLevelMin << " " << o.surfaceLevelMax << "); patchInfo { type wall; } }\n";
    const Vec3d wakeLo{lo.x - 2 * L, lo.y - 0.25 * L, lo.z - 0.25 * L}, wakeHi{hi.x + 0.25 * L, hi.y + 0.25 * L, hi.z + 0.25 * L};
    s << "    }\n    resolveFeatureAngle 30;\n    refinementRegions\n    {\n        wake { mode inside; levels ((1E15 "
      << std::max(1, o.surfaceLevelMin - 1) << ")); }\n    }\n"
      << "    locationInMesh " << vec({hi.x + 0.5 * o.upstream * L, 0.37 * (dlo.y + dhi.y) + 0.013 * L, 0.41 * (dlo.z + dhi.z) + 0.017 * L}) << ";\n"
      << "    allowFreeStandingZoneFaces true;\n}\n\n"
      << "snapControls\n{\n    nSmoothPatch 3;\n    tolerance 2.0;\n    nSolveIter 50;\n    nRelaxIter 5;\n    nFeatureSnapIter 10;\n"
         "    implicitFeatureSnap true;\n    explicitFeatureSnap false;\n    multiRegionFeatureSnap false;\n}\n\n"
      << "addLayersControls\n{\n    relativeSizes true;\n    layers\n    {\n";
    for (const auto& p : patches) s << "        \"" << p.patch << "\" { nSurfaceLayers " << std::max(o.layers, 1) << "; }\n";
    s << "    }\n    expansionRatio 1.2;\n    finalLayerThickness 0.5;\n    minThickness 0.1;\n    nGrow 0;\n    featureAngle 60;\n"
         "    slipFeatureAngle 30;\n    nRelaxIter 3;\n    nSmoothSurfaceNormals 1;\n    nSmoothNormals 3;\n    nSmoothThickness 10;\n"
         "    maxFaceThicknessRatio 0.5;\n    maxThicknessToMedialRatio 0.3;\n    minMedialAxisAngle 90;\n    nBufferCellsNoExtrude 0;\n"
         "    nLayerIter 50;\n}\n\n"
      << "meshQualityControls\n{\n    maxNonOrtho 65;\n    maxBoundarySkewness 20;\n    maxInternalSkewness 4;\n    maxConcave 80;\n"
         "    minVol 1e-13;\n    minTetQuality 1e-15;\n    minArea -1;\n    minTwist 0.02;\n    minDeterminant 0.001;\n    minFaceWeight 0.05;\n"
         "    minVolRatio 0.01;\n    minTriangleTwist -1;\n    nSmoothScale 4;\n    errorReduction 0.75;\n}\n\nmergeTolerance 1e-6;\n";
    // the wake box is a searchableBox (OpenFOAM.com and Foundation share the syntax)
    std::string snappy = s.str();
    const std::string geomEnd = "}\n\ncastellatedMeshControls";
    snappy.replace(snappy.find(geomEnd), geomEnd.size(), "    wake { type searchableBox; min " + vec(wakeLo) + "; max " + vec(wakeHi) + "; }\n" + geomEnd);
    if (!writeFile(dir / "system" / "snappyHexMeshDict", snappy, error)) return false;

    // controlDict with per-part forces
    s.str("");
    s << header("dictionary", "controlDict", "system") << "application     " << (o.steady ? "simpleFoam" : "pimpleFoam") << ";\n"
      << "startFrom       latestTime;\nstartTime       0;\nstopAt          endTime;\nendTime         " << num(endTime) << ";\n"
      << "deltaT          " << num(deltaT) << ";\nwriteControl    " << (o.steady ? "timeStep" : "adjustableRunTime") << ";\n"
      << "writeInterval   " << num(writeInterval) << ";\npurgeWrite      2;\nwriteFormat     ascii;\nwritePrecision  7;\n"
      << "timeFormat      general;\ntimePrecision   8;\nrunTimeModifiable true;\n";
    if (!o.steady) s << "adjustTimeStep  yes;\nmaxCo           2;\n";
    s << "\nfunctions\n{\n";
    auto forcesFO = [&](const std::string& name, const std::string& patchList) {
        s << "    " << name << "\n    {\n        type            forces;\n        libs            (\"libforces.so\");\n"
          << "        writeControl    timeStep;\n        writeInterval   1;\n        patches         (" << patchList << ");\n"
          << "        rho             rhoInf;\n        rhoInf          " << num(rho) << ";\n        CofR            (0 0 0);\n    }\n";
    };
    std::string all;
    for (const auto& p : patches) { forcesFO("forces_" + p.patch, p.patch); all += p.patch + " "; }
    forcesFO("forces_total", all);
    s << "    yPlus { type yPlus; libs (\"libfieldFunctionObjects.so\"); writeControl writeTime; }\n}\n";
    if (!writeFile(dir / "system" / "controlDict", s.str(), error)) return false;

    // fvSchemes / fvSolution
    s.str("");
    s << header("dictionary", "fvSchemes", "system") << "ddtSchemes\n{\n    default         " << (o.steady ? "steadyState" : "backward") << ";\n}\n\n"
      << "gradSchemes\n{\n    default         Gauss linear;\n    grad(U)         cellLimited Gauss linear 1;\n}\n\n"
      << "divSchemes\n{\n    default         none;\n    div(phi,U)      " << (o.steady ? "bounded " : "") << "Gauss linearUpwind grad(U);\n"
      << "    div(phi,k)      " << (o.steady ? "bounded " : "") << "Gauss upwind;\n    div(phi,omega)  " << (o.steady ? "bounded " : "") << "Gauss upwind;\n"
      << "    div((nuEff*dev2(T(grad(U))))) Gauss linear;\n}\n\n"
      << "laplacianSchemes\n{\n    default         Gauss linear limited corrected 0.33;\n}\n\n"
      << "interpolationSchemes\n{\n    default         linear;\n}\n\nsnGradSchemes\n{\n    default         limited corrected 0.33;\n}\n\n"
      << "wallDist\n{\n    method meshWave;\n}\n";
    if (!writeFile(dir / "system" / "fvSchemes", s.str(), error)) return false;
    s.str("");
    s << header("dictionary", "fvSolution", "system") << "solvers\n{\n"
      << "    p\n    {\n        solver          GAMG;\n        smoother        GaussSeidel;\n        tolerance       1e-7;\n        relTol          0.01;\n    }\n"
      << "    pFinal\n    {\n        $p;\n        relTol          0;\n    }\n"
      << "    \"(U|k|omega)\"\n    {\n        solver          smoothSolver;\n        smoother        symGaussSeidel;\n        tolerance       1e-8;\n"
      << "        relTol          0.1;\n    }\n    \"(U|k|omega)Final\"\n    {\n        $U;\n        relTol          0;\n    }\n}\n\n";
    if (o.steady)
        s << "SIMPLE\n{\n    nNonOrthogonalCorrectors 1;\n    consistent      yes;\n    residualControl\n    {\n        p 1e-5;\n        U 1e-6;\n"
             "        \"(k|omega)\" 1e-6;\n    }\n}\n\nrelaxationFactors\n{\n    equations\n    {\n        U 0.9;\n        \".*\" 0.7;\n    }\n}\n";
    else
        s << "PIMPLE\n{\n    nOuterCorrectors 2;\n    nCorrectors     2;\n    nNonOrthogonalCorrectors 1;\n}\n\n"
             "relaxationFactors\n{\n    equations\n    {\n        \".*\" 1;\n    }\n}\n";
    if (!writeFile(dir / "system" / "fvSolution", s.str(), error)) return false;
    s.str("");
    s << header("dictionary", "decomposeParDict", "system") << "numberOfSubdomains " << std::max(1, o.processors) << ";\nmethod scotch;\n";
    if (!writeFile(dir / "system" / "decomposeParDict", s.str(), error)) return false;

    // constant: both naming generations
    s.str("");
    s << header("dictionary", "transportProperties", "constant") << "transportModel  Newtonian;\nnu              " << num(nu) << ";\n";
    if (!writeFile(dir / "constant" / "transportProperties", s.str(), error)) return false;
    s.str("");
    s << header("dictionary", "physicalProperties", "constant") << "viscosityModel  constant;\nnu              " << num(nu) << ";\n";
    if (!writeFile(dir / "constant" / "physicalProperties", s.str(), error)) return false;
    const std::string turb = "simulationType  RAS;\n\nRAS\n{\n    model           " + o.turbulenceModel + ";\n    RASModel        " +
                             o.turbulenceModel + ";\n    turbulence      on;\n    printCoeffs     on;\n}\n";
    if (!writeFile(dir / "constant" / "turbulenceProperties", header("dictionary", "turbulenceProperties", "constant") + turb, error)) return false;
    if (!writeFile(dir / "constant" / "momentumTransport", header("dictionary", "momentumTransport", "constant") + turb, error)) return false;

    // 0/: initial and boundary conditions
    std::string wallsU, wallsP, wallsK, wallsW, wallsNut;
    for (const auto& p : patches) {
        wallsU += "    " + p.patch + " { type noSlip; }\n";
        wallsP += "    " + p.patch + " { type zeroGradient; }\n";
        wallsK += "    " + p.patch + " { type kqRWallFunction; value uniform " + num(k) + "; }\n";
        wallsW += "    " + p.patch + " { type omegaWallFunction; value uniform " + num(omega) + "; }\n";
        wallsNut += "    " + p.patch + " { type nutUSpaldingWallFunction; value uniform 0; }\n";
    }
    auto field = [&](const char* cls, const char* name, const char* dims, const std::string& internal, const std::string& inlet,
                     const std::string& outlet, const std::string& sides, const std::string& walls) {
        return header(cls, name, "0") + "dimensions      " + dims + ";\n\ninternalField   " + internal + ";\n\nboundaryField\n{\n    inlet  { " + inlet +
               " }\n    outlet { " + outlet + " }\n    sides  { " + sides + " }\n" + walls + "}\n";
    };
    const std::string uv = "uniform " + vec(Uinf);
    const bool ok0 =
        writeFile(dir / "0" / "U", field("volVectorField", "U", "[0 1 -1 0 0 0 0]", uv, "type fixedValue; value " + uv + ";",
                                         "type inletOutlet; inletValue " + uv + "; value " + uv + ";", "type slip;", wallsU), error) &&
        writeFile(dir / "0" / "p", field("volScalarField", "p", "[0 2 -2 0 0 0 0]", "uniform 0", "type zeroGradient;", "type fixedValue; value uniform 0;",
                                         "type slip;", wallsP), error) &&
        writeFile(dir / "0" / "k", field("volScalarField", "k", "[0 2 -2 0 0 0 0]", "uniform " + num(k), "type fixedValue; value uniform " + num(k) + ";",
                                         "type inletOutlet; inletValue uniform " + num(k) + "; value uniform " + num(k) + ";", "type slip;", wallsK), error) &&
        writeFile(dir / "0" / "omega", field("volScalarField", "omega", "[0 0 -1 0 0 0 0]", "uniform " + num(omega),
                                             "type fixedValue; value uniform " + num(omega) + ";",
                                             "type inletOutlet; inletValue uniform " + num(omega) + "; value uniform " + num(omega) + ";", "type slip;", wallsW),
                  error) &&
        writeFile(dir / "0" / "nut", field("volScalarField", "nut", "[0 2 -1 0 0 0 0]", "uniform 0", "type calculated; value uniform 0;",
                                           "type calculated; value uniform 0;", "type slip;", wallsNut), error);
    if (!ok0) return false;

    // Allrun + part manifest + README
    const std::string solver = o.steady ? "simpleFoam" : "pimpleFoam";
    s.str("");
    s << "#!/bin/sh\n# Plane World OpenFOAM reference case: mesh + " << solver << ". Needs the OpenFOAM environment (etc/bashrc) sourced.\n"
      << "cd \"$(dirname \"$0\")\" || exit 1\nset -e\n"
      << "blockMesh > log.blockMesh 2>&1\nsnappyHexMesh -overwrite > log.snappyHexMesh 2>&1\ncheckMesh > log.checkMesh 2>&1 || true\n";
    if (o.processors > 1)
        s << "decomposePar -force > log.decomposePar 2>&1\nmpirun -np " << o.processors << " " << solver << " -parallel > log." << solver
          << " 2>&1\nreconstructPar -latestTime > log.reconstructPar 2>&1\n";
    else s << solver << " > log." << solver << " 2>&1\n";
    s << "touch pw_done\n";
    if (!writeFile(dir / "Allrun", s.str(), error)) return false;
    std::error_code ec;
    fs::permissions(dir / "Allrun", fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec, fs::perm_options::add, ec);
    s.str("");
    for (const auto& p : patches) s << p.partIndex << " " << p.patch << "\n";
    if (!writeFile(dir / "pw_parts.txt", s.str(), error)) return false;
    s.str("");
    s << "Plane World OpenFOAM reference case\n===================================\n"
      << "craft: " << craft.name << "\nflight condition: V = " << o.speed << " m/s along +x (free stream U = " << vec(Uinf) << "), alpha = " << o.alphaDeg
      << " deg (craft rotated about +z), altitude " << o.altitude << " m: rho = " << num(rho) << " kg/m3, nu = " << num(nu) << " m2/s\n"
      << "solver: " << solver << " (" << (o.steady ? "steady RANS" : "transient URANS") << "), turbulence " << o.turbulenceModel
      << ", automatic wall treatment (Spalding nut, omega wall function)\n"
      << "mesh: blockMesh " << nc[0] << "x" << nc[1] << "x" << nc[2] << " (h = " << num(h0) << " m) + snappyHexMesh level (" << o.surfaceLevelMin << " "
      << o.surfaceLevelMax << ") on " << patches.size() << " part patches" << (o.layers > 0 ? ", " + std::to_string(o.layers) + " prism layers" : "") << "\n"
      << "forces: postProcessing/forces_<patch>/ (N, moments about the CoM = origin, world axes); props are not meshed.\n\n"
      << "Run:   ./Allrun        (or pwcli --openfoam-run <dir>)\nCompare: pwcli --aero-compare <craft> --speed " << o.speed << " --alpha "
      << o.alphaDeg << " --openfoam " << dirStr << "\n";
    if (!writeFile(dir / "README.txt", s.str(), error)) return false;
    if (patchesOut) *patchesOut = patches;
    return true;
}

bool toolAvailable(const std::string& tool) {
    const std::string cmd = "command -v " + tool + " > /dev/null 2>&1";
    return std::system(cmd.c_str()) == 0;
}

bool runCase(const std::string& dir, std::string* error) {
    if (!toolAvailable("blockMesh") || !toolAvailable("snappyHexMesh")) {
        if (error) *error = "OpenFOAM tools (blockMesh, snappyHexMesh, simpleFoam / pimpleFoam) not on PATH: source OpenFOAM's etc/bashrc first";
        return false;
    }
    const std::string cmd = "sh \"" + dir + "/Allrun\" > \"" + dir + "/log.Allrun\" 2>&1";
    if (std::system(cmd.c_str()) != 0 || !fs::exists(fs::path(dir) / "pw_done")) {
        if (error) *error = "Allrun failed: see " + dir + "/log.* files";
        return false;
    }
    return true;
}

namespace {
/// Numbers of one data line with parentheses removed; empty for comments.
std::vector<double> numbers(const std::string& line) {
    std::vector<double> out;
    if (line.empty() || line[0] == '#') return out;
    std::string t = line;
    for (char& c : t) if (c == '(' || c == ')' || c == '\t' || c == ',') c = ' ';
    std::istringstream s(t);
    double v;
    while (s >> v) out.push_back(v);
    return out;
}

/// Averages columns [c0, c0 + 3) (and, when c1 >= 0, adds [c1, c1 + 3)) over the last `tail` of the file's rows.
bool tailAverage(const fs::path& p, int c0, int c1, double tail, Vec3d& out, int& n) {
    std::ifstream f(p);
    if (!f) return false;
    std::vector<std::vector<double>> rows;
    std::string line;
    while (std::getline(f, line)) { auto v = numbers(line); if (v.size() >= std::size_t(std::max(c0, c1) + 4)) rows.push_back(std::move(v)); }
    if (rows.empty()) return false;
    const std::size_t start = rows.size() - std::max<std::size_t>(1, std::size_t(double(rows.size()) * std::clamp(tail, 0.0, 1.0)));
    out = {};
    n = 0;
    for (std::size_t i = start; i < rows.size(); ++i) {
        Vec3d v{rows[i][std::size_t(c0 + 1)], rows[i][std::size_t(c0 + 2)], rows[i][std::size_t(c0 + 3)]};
        if (c1 >= 0) v += Vec3d{rows[i][std::size_t(c1 + 1)], rows[i][std::size_t(c1 + 2)], rows[i][std::size_t(c1 + 3)]};
        out += v;
        ++n;
    }
    out = out / double(std::max(n, 1));
    return true;
}

/// Latest-started time directory of a function object's output (restarts write new ones).
fs::path latestTimeDir(const fs::path& fo) {
    fs::path best;
    double bt = -1e300;
    std::error_code ec;
    for (const auto& e : fs::directory_iterator(fo, ec)) {
        if (!e.is_directory()) continue;
        char* end = nullptr;
        const std::string n = e.path().filename().string();
        const double t = std::strtod(n.c_str(), &end);
        if (end && *end == 0 && t > bt) { bt = t; best = e.path(); }
    }
    return best;
}
} // namespace

bool readForces(const std::string& dirStr, std::vector<PartForce>& out, double tail, std::string* error) {
    const fs::path dir(dirStr);
    std::ifstream m(dir / "pw_parts.txt");
    if (!m) { if (error) *error = "not a Plane World OpenFOAM case (no pw_parts.txt): " + dirStr; return false; }
    out.clear();
    int idx;
    std::string patch;
    while (m >> idx >> patch) {
        PartForce pf;
        pf.partIndex = idx; pf.patch = patch;
        const fs::path t = latestTimeDir(dir / "postProcessing" / ("forces_" + patch));
        Vec3d F, M;
        int n = 0, nm = 0;
        bool ok = false;
        if (!t.empty()) {
            // OpenFOAM.com v2006+: force.dat / moment.dat = time, total, pressure, viscous
            ok = tailAverage(t / "force.dat", 0, -1, tail, F, n);
            if (ok && !tailAverage(t / "moment.dat", 0, -1, tail, M, nm)) M = {};
            // Foundation: forces.dat = time ((pressure) (viscous) [porous]) ((pressure moment) (viscous moment) [porous])
            if (!ok && tailAverage(t / "forces.dat", 0, 3, tail, F, n)) {
                ok = true;
                std::ifstream f(t / "forces.dat");
                std::string line;
                int cols = 0;
                while (std::getline(f, line)) { auto v = numbers(line); if (!v.empty()) { cols = int(v.size()); break; } }
                const int mo = cols >= 19 ? 9 : 6;   // with or without porous columns
                if (!tailAverage(t / "forces.dat", mo, mo + 3, tail, M, nm)) M = {};
            }
        }
        if (ok) { pf.ft = sim::ForceTorque{F, M}; pf.samples = n; }
        out.push_back(pf);
    }
    if (out.empty()) { if (error) *error = "no parts in pw_parts.txt"; return false; }
    bool any = false;
    for (const auto& p : out) any = any || p.samples > 0;
    if (!any && error) *error = "no force data under " + (dir / "postProcessing").string() + " (has the case run?)";
    return any;
}

} // namespace pw::flow::openfoam
