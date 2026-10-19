#pragma once
// OpenFOAM offline reference ("CFD · OpenFOAM reference", not a live flight model): writes a complete case for a craft
// held at one flight condition, optionally runs it when the OpenFOAM tools are on PATH, and reads the per-part forces
// back for pwcli --aero-compare. Nothing is linked: the case is plain text files and OpenFOAM runs as a subprocess, so
// OpenFOAM's GPL does not touch this program.
//
// Case: one ASCII STL per part (constant/triSurface/<patch>.stl, world axes, CoM at the origin), blockMesh background
// box (upstream / downstream / lateral padding in craft lengths), snappyHexMesh surface refinement (+ optional
// prism layers), incompressible solver with k-omega SST: pimpleFoam (transient URANS, the default) or simpleFoam
// (steady RANS); automatic wall treatment (nutUSpaldingWallFunction, omegaWallFunction, kqRWallFunction); one
// `forces` function object per part patch plus the total (rho rhoInf, CofR = CoM), so the forces are in newtons and
// the moments about the CoM, in the same world axes as the in-app CFD. Files are written for OpenFOAM.com (v2006+:
// transportProperties, turbulenceProperties) and the Foundation releases (v9+: physicalProperties,
// momentumTransport). See docs/CFD_NS.md, section "OpenFOAM reference".
#include <string>
#include <vector>
#include "pw/math.h"
#include "pw/sim/cfd.h"

namespace pw::craft { struct CraftDocument; }

namespace pw::flow::openfoam {

struct CaseOptions {
    double speed = 20;              // m/s, craft velocity along +x (world)
    double alphaDeg = 0;            // pitch attitude: craft rotated about +z (as pwcli --aero-compare)
    double altitude = 200;          // m (ISA density / viscosity)
    bool steady = false;            // false: pimpleFoam (URANS, default); true: simpleFoam (steady RANS)
    std::string turbulenceModel = "kOmegaSST";
    double upstream = 3, downstream = 6, lateral = 3;    // domain padding in craft lengths L (largest extent)
    int backgroundCells = 8;        // background cells along the craft length L (snappy refines the surfaces)
    int surfaceLevelMin = 3, surfaceLevelMax = 4;        // snappy refinement levels on the parts
    int layers = 0;                 // prism layers on the parts (0 = none: wall functions on the castellated cells)
    double endTime = 0;             // 0 = automatic (steady: 1500 iterations; transient: 10 flow-through times of L)
    double turbulenceIntensity = 0.005, viscosityRatio = 1.0;
    int processors = 1;             // > 1: decomposePar + mpirun in Allrun
};

struct PartPatch {
    int partIndex = -1;
    std::string patch, name, type;
};

/// Writes the case into `dir` (created; existing OpenFOAM files are overwritten). `parts` = aeroParts(craft) order.
/// Returns false and sets *error on failure.
bool exportCase(const craft::CraftDocument& flightCraft, const CaseOptions& o, const std::string& dir, std::vector<PartPatch>* patches = nullptr,
                std::string* error = nullptr);

/// True when `tool` (e.g. "simpleFoam") is found on PATH.
bool toolAvailable(const std::string& tool);

/// Runs <dir>/Allrun (mesh + solver; log in <dir>/log.Allrun). Blocking. False if the tools are missing or it failed.
bool runCase(const std::string& dir, std::string* error = nullptr);

struct PartForce {
    int partIndex = -1;
    std::string patch;
    sim::ForceTorque ft;            // world axes, N and N m about the CoM; averaged over the last `tail` of the run
    int samples = 0;
};

/// Reads postProcessing/forces_<patch>/<time>/force.dat + moment.dat (OpenFOAM.com) or forces.dat (Foundation) for
/// every patch in <dir>/pw_parts.txt, averaging the last `tail` fraction of the samples.
bool readForces(const std::string& dir, std::vector<PartForce>& out, double tail = 0.3, std::string* error = nullptr);

} // namespace pw::flow::openfoam
