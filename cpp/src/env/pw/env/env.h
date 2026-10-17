#pragma once
// pwenv entry points: register the terrain / water / vegetation self-tests and install the full terrain builder
// into the headless world bake (erosion, PNG heightmaps, DEM tiles, sculpt / paint edits).
namespace pw::env {
/// Idempotent. Registers "terrain.*", "water.*", "vegetation.*" and "env.*" self-tests.
void registerSelfTests();
/// Idempotent. world::bakeTerrain then builds terrain through terrain::TerrainSystem. Erosion in headless bakes runs
/// on the CPU (deterministic, identical on every platform) unless PW_BAKE_EROSION=gpu.
void install();
}
