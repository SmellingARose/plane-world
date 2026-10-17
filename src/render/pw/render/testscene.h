#pragma once
// Offscreen test scene (same as the Swift `render.offscreen` self-test: 20 km ground with the grid pattern, a red
// box and a mirror sphere, camera looking at (0,1,0) from (8,4,10)) plus image helpers for screenshot tests.
#include <string>
#include <vector>
#include "pw/gpu.h"
#include "pw/render/renderer.h"

namespace pw::craft { struct CraftDocument; }

namespace pw::render {

struct ShotOptions {
    int width = 640, height = 360, frames = 8;
    const craft::CraftDocument* craft = nullptr;   // also draw this craft (rest pose) next to the box
    bool debugLines = false;                       // draw a few debug lines (axes) too
    int asyncCompute = -1;                         // RenderSettings::asyncCompute
};
struct ShotResult {
    bool ok = false;
    std::string message;
    std::vector<uint8_t> rgba;                     // top row first
    int width = 0, height = 0;
    double gpuMs = 0;
    std::vector<gpu::TimerResult> passes;
    bool asyncCompute = false;
    int executedPasses = 0;
};
/// Renders opts.frames frames (time i/60) and reads back the last one.
ShotResult renderTestScene(gpu::Device& dev, const ShotOptions& opts);

/// PSNR over RGB (dB, 99 for identical images).
double psnr(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b);
/// Reads the PNG subset written by gpu::writePNG / tools/png_stored.py (RGBA8, filter 0, stored deflate).
bool readPNG(const std::string& path, std::vector<uint8_t>& rgba, int& width, int& height);
/// Basic sanity checks shared by the tests: blue-dominant sky on the top row, mostly non-black image.
bool plausibleSky(const std::vector<uint8_t>& rgba, int w, int h, std::string* why);

} // namespace pw::render
