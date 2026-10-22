#pragma once
// Built-in procedural world presets (WORLD tab "New world" menu). Pure data generation, no downloads.
#include "pw/world/document.h"
#include <optional>
#include <string>

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
/// "Los Angeles (Downtown)": DTLA's rotated grid with Bunker Hill's towers (Wilshire Grand, U.S. Bank Tower, Aon, the
/// California Plazas), City Hall, Disney Hall, the low stucco sprawl, the 110 / 101 freeways, palms, and the hills to
/// the north with the Hollywood sign and Griffith Observatory (moved closer so they share a shot with downtown).
WorldDocument losAngeles();
/// "Tel Aviv (Coast)": the Mediterranean, the beach and promenade, the hotel wall, the white Bauhaus city, the Ayalon
/// and its towers (Azrieli Center, Sarona), Reading power station to the north and Old Jaffa on its hill to the south.
WorldDocument telAviv();
/// "Dubai (Downtown)": Burj Khalifa, Sheikh Zayed Road's tower canyon, downtown blocks, desert and the Gulf coast.
WorldDocument dubai();
/// A city preset by key ("manhattan", "losangeles", "telaviv", "dubai"); nullopt when unknown.
std::optional<WorldDocument> city(const std::string& key);
} // namespace pw::world::presets
