// Hydraulic + thermal erosion: GPU (shaders/env/erosion.slang through pwgpu compute) and a CPU implementation of
// the very same kernels (float math, gather form, rows in parallel: deterministic and bit-identical across
// platforms because it only uses + - * / sqrt min max floor). Port of Sources/Terrain/TerrainErosion.swift.
#include <algorithm>
#include <chrono>
#include <cmath>
#include "env_gpu.h"
#include "pw/env/terrain.h"
#include "pw/jobs.h"

namespace pw::terrain {
namespace {

struct ErosionU {
    uint32_t w, h; float cell, dt;
    float rain, evap, Kc, Ks;
    float Kd, maxDepth, talus, thermal;
    uint32_t iter; float strength, pad0, pad1;
};
static_assert(sizeof(ErosionU) == 64);

struct F2 { float x, y; };
struct F4 { float x, y, z, w; };

// ---------------------------------------------------------------- CPU kernels (mirror erosion.slang line by line)

struct CPUState {
    const ErosionU* u;
    int W, H;
    inline uint32_t idx(int x, int y) const { return uint32_t(std::clamp(y, 0, H - 1)) * uint32_t(W) + uint32_t(std::clamp(x, 0, W - 1)); }
};
inline float ehash(uint32_t a, uint32_t c) {
    uint32_t hh = a * 747796405u + c * 2891336453u;
    hh = ((hh >> ((hh >> 28u) + 4u)) ^ hh) * 277803737u;
    hh = (hh >> 22u) ^ hh;
    return float(hh) / 4294967295.0f;
}
inline float clampf(float v, float a, float b) { return std::min(std::max(v, a), b); }

void cpuRainFlux(const CPUState& s, const float* b, const float* d, F4* flux) {
    const ErosionU& u = *s.u;
    jobs::JobSystem::shared().parallelFor(s.H, 8, [&](int ya, int yb) {
        for (int y = ya; y < yb; ++y)
            for (int x = 0; x < s.W; ++x) {
                uint32_t i = s.idx(x, y);
                float water = d[i];
                float H = b[i] + water;
                const float A = u.cell * u.cell * 0.25f, g9 = 9.81f;
                F4 f = flux[i];
                float hL = x > 0 ? b[s.idx(x - 1, y)] + d[s.idx(x - 1, y)] : 1e9f;
                float hR = x < s.W - 1 ? b[s.idx(x + 1, y)] + d[s.idx(x + 1, y)] : 1e9f;
                float hT = y > 0 ? b[s.idx(x, y - 1)] + d[s.idx(x, y - 1)] : 1e9f;
                float hB = y < s.H - 1 ? b[s.idx(x, y + 1)] + d[s.idx(x, y + 1)] : 1e9f;
                float k = u.dt * A * g9 / u.cell;
                f.x = std::max(0.0f, f.x * 0.995f + k * (H - hL));
                f.y = std::max(0.0f, f.y * 0.995f + k * (H - hR));
                f.z = std::max(0.0f, f.z * 0.995f + k * (H - hT));
                f.w = std::max(0.0f, f.w * 0.995f + k * (H - hB));
                float outF = f.x + f.y + f.z + f.w;
                float vol = water * u.cell * u.cell;
                if (outF * u.dt > vol) {
                    float sc = vol / std::max(outF * u.dt, 1e-9f);
                    f.x *= sc; f.y *= sc; f.z *= sc; f.w *= sc;
                }
                flux[i] = f;
            }
    }, "erosion.flux");
}

void cpuWaterSediment(const CPUState& s, const float* b, float* d, const F4* flux, F2* vel, const float* sIn, float* sOut,
                      float* moist, float* bOut) {
    const ErosionU& u = *s.u;
    jobs::JobSystem::shared().parallelFor(s.H, 8, [&](int ya, int yb) {
        for (int y = ya; y < yb; ++y)
            for (int x = 0; x < s.W; ++x) {
                uint32_t i = s.idx(x, y);
                F4 f = flux[i];
                float inL = x > 0 ? flux[s.idx(x - 1, y)].y : 0.0f;
                float inR = x < s.W - 1 ? flux[s.idx(x + 1, y)].x : 0.0f;
                float inT = y > 0 ? flux[s.idx(x, y - 1)].w : 0.0f;
                float inB = y < s.H - 1 ? flux[s.idx(x, y + 1)].z : 0.0f;
                float dV = u.dt * ((inL + inR + inT + inB) - (f.x + f.y + f.z + f.w));
                float d0 = d[i];
                float d1 = std::max(0.0f, d0 + dV / (u.cell * u.cell));
                float dAvg = std::max(0.5f * (d0 + d1), 1e-3f);
                float wx = 0.5f * (inL - f.x + f.y - inR), wy = 0.5f * (inT - f.z + f.w - inB);
                float den = u.cell * dAvg;
                F2 v{wx / den, wy / den};
                float vmax = 0.5f * u.cell / u.dt;
                float vl = std::sqrt(v.x * v.x + v.y * v.y);
                if (vl > vmax) { float sc = vmax / vl; v.x *= sc; v.y *= sc; }
                vel[i] = v;
                float r = ehash(uint32_t(x) / 16u + (u.iter / 16u) * 7919u, uint32_t(y) / 16u + u.iter / 16u);
                float water = d1 + u.rain * u.dt * (0.4f + 1.2f * r);
                moist[i] += std::min(d1, 2.0f) + 0.02f * std::min(vl, 10.0f);
                float bx = (b[s.idx(x + 1, y)] - b[s.idx(x - 1, y)]) / (2.0f * u.cell);
                float by = (b[s.idx(x, y + 1)] - b[s.idx(x, y - 1)]) / (2.0f * u.cell);
                float slope2 = bx * bx + by * by;
                float sinA = std::sqrt(slope2 / (1.0f + slope2));
                float depthTerm = clampf(1.0f - std::max(0.0f, u.maxDepth - water) / u.maxDepth, 0.0f, 1.0f);
                depthTerm = std::sqrt(depthTerm);
                float C = u.Kc * u.strength * std::max(sinA, 0.03f) * std::sqrt(v.x * v.x + v.y * v.y) * depthTerm;
                float sed = sIn[i];
                float bb = b[i];
                if (C > sed) {
                    float e = std::min(u.Ks * u.dt * (C - sed), 0.05f * u.cell);
                    bb -= e; sed += e;
                } else {
                    float dep = u.Kd * u.dt * (sed - C);
                    bb += dep; sed -= dep;
                }
                bOut[i] = bb;
                sOut[i] = sed;
                d[i] = water * (1.0f - u.evap * u.dt);
            }
    }, "erosion.water");
}

void cpuAdvect(const CPUState& s, const F2* vel, const float* src, float* dst) {
    const ErosionU& u = *s.u;
    jobs::JobSystem::shared().parallelFor(s.H, 8, [&](int ya, int yb) {
        for (int y = ya; y < yb; ++y)
            for (int x = 0; x < s.W; ++x) {
                uint32_t i = s.idx(x, y);
                float px = float(x) - vel[i].x * u.dt / u.cell, py = float(y) - vel[i].y * u.dt / u.cell;
                px = clampf(px, 0.0f, float(u.w - 1)); py = clampf(py, 0.0f, float(u.h - 1));
                int p0x = int(std::floor(px)), p0y = int(std::floor(py));
                float frx = px - float(p0x), fry = py - float(p0y);
                float s00 = src[s.idx(p0x, p0y)], s10 = src[s.idx(p0x + 1, p0y)], s01 = src[s.idx(p0x, p0y + 1)], s11 = src[s.idx(p0x + 1, p0y + 1)];
                float a = s00 + (s10 - s00) * frx, c = s01 + (s11 - s01) * frx;   // lerp(a, b, t) = a + (b - a) t
                dst[i] = a + (c - a) * fry;
            }
    }, "erosion.advect");
}

inline float thermalOut(const CPUState& s, const float* b, int x, int y, float& total) {
    const ErosionU& u = *s.u;
    float hgt = b[s.idx(x, y)], maxD = 0.0f; total = 0.0f;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float dist = (dx != 0 && dy != 0) ? 1.41421f : 1.0f;
            float diff = hgt - b[s.idx(x + dx, y + dy)];
            if (diff / (dist * u.cell) > u.talus) { total += diff; maxD = std::max(maxD, diff); }
        }
    return maxD;
}

void cpuThermal(const CPUState& s, const float* b, float* bOut) {
    const ErosionU& u = *s.u;
    jobs::JobSystem::shared().parallelFor(s.H, 8, [&](int ya, int yb) {
        for (int y = ya; y < yb; ++y)
            for (int x = 0; x < s.W; ++x) {
                float hgt = b[s.idx(x, y)];
                float myTotal; float myMax = thermalOut(s, b, x, y, myTotal);
                float moved = myTotal > 0.0f ? u.thermal * 0.5f * (myMax - u.talus * u.cell) : 0.0f;
                moved = std::max(moved, 0.0f);
                float delta = -moved;
                for (int dy = -1; dy <= 1; dy++)
                    for (int dx = -1; dx <= 1; dx++) {
                        if (dx == 0 && dy == 0) continue;
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= s.W || ny >= s.H) continue;
                        float nTotal; float nMax = thermalOut(s, b, nx, ny, nTotal);
                        if (nTotal <= 0.0f) continue;
                        float diff = b[s.idx(nx, ny)] - hgt;
                        float dist = (dx != 0 && dy != 0) ? 1.41421f : 1.0f;
                        if (diff / (dist * u.cell) > u.talus) {
                            float nMoved = std::max(0.0f, u.thermal * 0.5f * (nMax - u.talus * u.cell));
                            delta += nMoved * diff / nTotal;
                        }
                    }
                bOut[uint32_t(y) * u.w + uint32_t(x)] = hgt + delta;
            }
    }, "erosion.thermal");
}

ErosionU makeUniforms(int w, int h, float cell, const ErosionParams& p) {
    ErosionU u{};
    u.w = uint32_t(w); u.h = uint32_t(h); u.cell = cell; u.dt = p.dt;
    u.rain = p.rain * cell / 8; u.evap = p.evaporation; u.Kc = p.capacity; u.Ks = p.dissolve;
    u.Kd = p.deposit; u.maxDepth = p.maxErosionDepth; u.talus = p.talusAngle; u.thermal = p.thermalRate;
    u.strength = p.strength;
    return u;
}

bool erodeCPU(int W, int H, float cell, const ErosionParams& p, std::vector<float>& b, std::vector<float>& sed, std::vector<float>& moist) {
    std::size_t n = std::size_t(W) * std::size_t(H);
    std::vector<float> bOther(n), d(n, 0), sB(n, 0);
    std::vector<F4> flux(n, F4{0, 0, 0, 0});
    std::vector<F2> vel(n, F2{0, 0});
    sed.assign(n, 0); moist.assign(n, 0);
    ErosionU u = makeUniforms(W, H, cell, p);
    CPUState s{&u, W, H};
    float* bCur = b.data();
    float* bOth = bOther.data();
    int total = p.iterations + p.thermalIterations;
    for (int it = 0; it < total; ++it) {
        u.iter = uint32_t(it);
        if (it < p.iterations) {
            cpuRainFlux(s, bCur, d.data(), flux.data());
            cpuWaterSediment(s, bCur, d.data(), flux.data(), vel.data(), sed.data(), sB.data(), moist.data(), bOth);
            std::swap(bCur, bOth);
            cpuAdvect(s, vel.data(), sB.data(), sed.data());
            if (it % 4 == 3) { cpuThermal(s, bCur, bOth); std::swap(bCur, bOth); }
        } else {
            cpuThermal(s, bCur, bOth); std::swap(bCur, bOth);
        }
    }
    if (bCur != b.data()) std::copy(bOther.begin(), bOther.end(), b.begin());
    return true;
}

bool erodeGPU(int W, int H, float cell, const ErosionParams& p, std::vector<float>& b, std::vector<float>& sed, std::vector<float>& moist,
              double& gpuMs, std::string& backend, std::string* err) {
    std::lock_guard<std::mutex> lk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c) { if (err) *err = "no GPU compute device"; return false; }
    backend = std::string(gpu::backendName(c->backend())) + " (" + c->adapterName() + ")";
    int kFlux = env::loadKernel(*c, "erosion", "erodeRainFlux", 16, 16, 1, err);
    int kWater = env::loadKernel(*c, "erosion", "erodeWaterSediment", 16, 16, 1, err);
    int kAdv = env::loadKernel(*c, "erosion", "erodeAdvect", 16, 16, 1, err);
    int kTherm = env::loadKernel(*c, "erosion", "erodeThermal", 16, 16, 1, err);
    if (!kFlux || !kWater || !kAdv || !kTherm) return false;
    std::size_t n = std::size_t(W) * std::size_t(H);
    int bA = c->createBuffer(n * 4, b.data()), bB = c->createBuffer(n * 4), water = c->createBuffer(n * 4), flux = c->createBuffer(n * 16),
        vel = c->createBuffer(n * 8), sA = c->createBuffer(n * 4), sB = c->createBuffer(n * 4), mo = c->createBuffer(n * 4);
    auto release = [&] { for (int h : {bA, bB, water, flux, vel, sA, sB, mo}) if (h) c->destroyBuffer(h); };
    if (!bA || !bB || !water || !flux || !vel || !sA || !sB || !mo) { if (err) *err = "GPU buffer allocation: " + c->lastError(); release(); return false; }
    ErosionU u = makeUniforms(W, H, cell, p);
    int gx = gpu::ComputeContext::groupsFor(W, 16), gy = gpu::ComputeContext::groupsFor(H, 16);
    int bCur = bA, bOth = bB;
    int total = p.iterations + p.thermalIterations, it = 0;
    gpuMs = 0;
    bool ok = true;
    while (it < total && ok) {
        c->begin();
        int batchEnd = std::min(total, it + 40);
        for (; it < batchEnd; ++it) {
            u.iter = uint32_t(it);
            if (it < p.iterations) {
                int bf[] = {bCur, water, flux};
                ok &= c->dispatch(kFlux, &u, sizeof u, bf, 3, gx, gy, 1);
                int bw[] = {bCur, water, flux, vel, sA, sB, mo, bOth};
                ok &= c->dispatch(kWater, &u, sizeof u, bw, 8, gx, gy, 1);
                std::swap(bCur, bOth);
                int ba[] = {0, 0, 0, vel, sA, sB};
                ok &= c->dispatch(kAdv, &u, sizeof u, ba, 6, gx, gy, 1);
                if (it % 4 == 3) {
                    int bt[] = {bCur, 0, 0, 0, 0, 0, 0, bOth};
                    ok &= c->dispatch(kTherm, &u, sizeof u, bt, 8, gx, gy, 1);
                    std::swap(bCur, bOth);
                }
            } else {
                int bt[] = {bCur, 0, 0, 0, 0, 0, 0, bOth};
                ok &= c->dispatch(kTherm, &u, sizeof u, bt, 8, gx, gy, 1);
                std::swap(bCur, bOth);
            }
        }
        double ms = c->end(true);   // -1 when timing is unavailable
        if (ms > 0) gpuMs += ms;
    }
    if (!ok) { if (err) *err = "dispatch failed: " + c->lastError(); release(); return false; }
    sed.resize(n); moist.resize(n);
    ok = c->download(bCur, b.data(), n * 4) && c->download(sA, sed.data(), n * 4) && c->download(mo, moist.data(), n * 4);
    if (!ok && err) *err = "download failed: " + c->lastError();
    release();
    return ok;
}

} // namespace

bool erodeRaw(int w, int h, float cell, const ErosionParams& p, ErosionDevice device, std::vector<float>& b, std::vector<float>& sed,
              std::vector<float>& moist, double* gpuMs, std::string* err) {
    if (device == ErosionDevice::CPU) return erodeCPU(w, h, cell, p, b, sed, moist);
    double ms = 0; std::string backend;
    std::vector<float> keep;
    if (device == ErosionDevice::Auto) keep = b;
    bool ok = erodeGPU(w, h, cell, p, b, sed, moist, ms, backend, err);
    if (gpuMs) *gpuMs = ms;
    if (!ok && device == ErosionDevice::Auto) { b = keep; return erodeCPU(w, h, cell, p, b, sed, moist); }
    return ok;
}

bool erode(HeightField& f, const ErosionParams& p, ErosionDevice device, ErosionResult& r, std::string* err) {
    const int W = f.width, H = f.height;
    const std::size_t n = std::size_t(W) * std::size_t(H);
    r = ErosionResult{};
    for (float v : f.base) r.volumeBefore += double(v);
    std::vector<float> b = f.base, sed, mo;
    auto t0 = std::chrono::steady_clock::now();
    bool ok = false;
    if (device != ErosionDevice::CPU) {
        std::string gerr;
        ok = erodeGPU(W, H, float(f.spacing), p, b, sed, mo, r.gpuMs, r.backend, &gerr);
        r.usedGPU = ok;
        if (!ok) {
            if (device == ErosionDevice::GPU) { if (err) *err = gerr; return false; }
            b = f.base;
        }
    }
    if (!ok) { erodeCPU(W, H, float(f.spacing), p, b, sed, mo); r.backend = "CPU (" + std::to_string(jobs::JobSystem::shared().threadCount()) + " threads)"; }
    r.cpuMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    // Deposit the suspended sediment back so mass is conserved; moisture = log-scaled time-averaged water depth
    // normalised by the 98th percentile.
    float iters = float(std::max(p.iterations, 1));
    std::vector<float> sample;
    for (std::size_t i = 0; i < n; i += std::max<std::size_t>(1, n / 4096)) sample.push_back(std::log(1 + mo[i] / iters * 20));
    std::sort(sample.begin(), sample.end());
    float p98 = std::max(sample[std::min(sample.size() - 1, sample.size() * 98 / 100)], 1e-4f);
    jobs::JobSystem::shared().parallelFor(int(n), 65536, [&](int a, int e) {
        for (std::size_t i = std::size_t(a); i < std::size_t(e); ++i) {
            f.base[i] = b[i] + sed[i];
            f.moisture[i] = std::min(1.0f, std::max(0.0f, std::log(1 + mo[i] / iters * 20) / p98));
        }
    }, "erosion.finish");
    for (float v : f.base) r.volumeAfter += double(v);
    return true;
}

} // namespace pw::terrain
