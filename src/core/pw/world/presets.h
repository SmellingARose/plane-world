#pragma once
// Built-in procedural world presets (WORLD tab "New world" menu). Pure data generation, no downloads.
#include "pw/world/document.h"

namespace pw::world::presets {
/// "Manhattan (Midtown)": the real street grid (rotated 29 deg, real avenue spacing, Broadway's diagonal) from 30th
/// to 96th St between the Hudson and the East River. Lot-level massing (several buildings per block, brownstones,
/// pre-war setbacks, glass towers with podiums, cornices, water towers, mechanical penthouses), modelled landmarks
/// (Empire State, Chrysler, One Vanderbilt, Grand Central + MetLife, 30 Rock, 432 Park, Billionaires' Row, Times
/// Square signs, St Patrick's, UN, Hudson Yards, MSG, Intrepid, Queensboro Bridge), Central Park with tree strokes,
/// the Reservoir / Lake / Pond as water, piers, and low-detail New Jersey / Roosevelt Island / Queens shores.
/// Deterministic. Objects use params color / shape / pattern / emissive / collide (see app/propbatches.h).
WorldDocument manhattanMidtown();
/// World position of a point in the Manhattan preset's grid frame: u metres east of Fifth Avenue (cross-town),
/// v metres north of 34th Street (80 m per street), y metres above the ground.
Vec3d manhattanPoint(double u, double v, double y);
} // namespace pw::world::presets
