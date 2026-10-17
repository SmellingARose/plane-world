// Tessendorf ocean: spectrum (Sources/Water/OceanSpectrum.swift), evolution + inverse FFT on the CPU or the GPU
// (Sources/Water/OceanGPU.swift, shaders/env/ocean.slang) and lock-free CPU sampling of the published sets.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include "env_gpu.h"
#include "pw/env/water.h"
#include "pw/jobs.h"

namespace pw::water {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kDeg = kPi / 180;
}

// ---------------------------------------------------------------- spectrum

OceanSpectrum::OceanSpectrum(const OceanSettings& s) : settings(s), N(s.resolution) {
    const auto& Ls = settings.patchSizes;
    geo::PCG32 rng(settings.seed);
    auto gauss = [&] {
        double u1 = std::max(rng.unit(), 1e-12), u2 = rng.unit();
        return std::sqrt(-2 * std::log(u1)) * std::cos(2 * kPi * u2);
    };
    double variance = 0;
    for (int ci = 0; ci < int(Ls.size()); ++ci) {
        OceanCascadeSpectrum c;
        c.L = Ls[std::size_t(ci)];
        c.kLow = ci == 0 ? 0 : kHighOf(ci - 1);
        c.kHigh = kHighOf(ci);
        std::size_t n = std::size_t(N) * std::size_t(N);
        c.h0.assign(n * 4, 0.0f);
        c.omega.assign(n, 0.0f);
        std::vector<double> raw(n * 2, 0.0);
        double dk = 2 * kPi / c.L;
        for (int y = 0; y < N; ++y)
            for (int x = 0; x < N; ++x) {
                double kx = double(x - N / 2) * dk, kz = double(y - N / 2) * dk;
                double k = std::sqrt(kx * kx + kz * kz);
                double g1 = gauss(), g2 = gauss();    // always draw to keep the stream stable
                if (!(k >= c.kLow && k < c.kHigh && k > 1e-6)) continue;
                double amp = std::sqrt(spectrum2D(kx, kz) * dk * dk / 2);
                std::size_t i = std::size_t(y) * std::size_t(N) + std::size_t(x);
                raw[i * 2] = g1 * (1 / std::sqrt(2.0)) * amp;
                raw[i * 2 + 1] = g2 * (1 / std::sqrt(2.0)) * amp;
                variance += amp * amp * 2;
                c.omega[i] = float(dispersion(k));
            }
        for (int y = 0; y < N; ++y)
            for (int x = 0; x < N; ++x) {
                int mx = (N - x) % N, my = (N - y) % N;
                std::size_t i = std::size_t(y) * std::size_t(N) + std::size_t(x), j = std::size_t(my) * std::size_t(N) + std::size_t(mx);
                c.h0[i * 4] = float(raw[i * 2]); c.h0[i * 4 + 1] = float(raw[i * 2 + 1]);
                c.h0[i * 4 + 2] = float(raw[j * 2]); c.h0[i * 4 + 3] = float(-raw[j * 2 + 1]);
            }
        cascades.push_back(std::move(c));
    }
    significantWaveHeight = 4 * std::sqrt(variance);
}

double OceanSpectrum::kHighOf(int ci) const {
    const auto& Ls = settings.patchSizes;
    if (ci < 0) return 0;
    if (ci + 1 < int(Ls.size())) return 2 * kPi / Ls[std::size_t(ci + 1)] * 6;
    return kPi * double(N) / Ls[std::size_t(ci)];   // Nyquist of the finest cascade
}

double OceanSpectrum::dispersion(double k) {
    double w0 = 2 * kPi / kOceanRepeatPeriod;
    double w = std::sqrt(kGravity * k);
    return std::floor(w / w0) * w0;
}

double OceanSpectrum::jonswap(double w) const {
    double g = kGravity;
    double U = std::max(settings.windSpeed, 0.01), F = std::max(settings.fetchKm, 0.1) * 1000;
    double alpha = 0.076 * std::pow(U * U / (F * g), 0.22);
    double wp = 22 * std::pow(g * g / (U * F), 1.0 / 3.0);
    if (!(w > 1e-4)) return 0;
    double sigma = w <= wp ? 0.07 : 0.09;
    double r = std::exp(-(w - wp) * (w - wp) / (2 * sigma * sigma * wp * wp));
    double s = alpha * g * g / std::pow(w, 5) * std::exp(-1.25 * std::pow(wp / w, 4)) * std::pow(settings.gamma, r);
    if (settings.swell > 0) {
        double ws = wp * 0.4;
        s += settings.swell * alpha * g * g / std::pow(w, 5) * std::exp(-1.25 * std::pow(ws / w, 4)) *
             std::pow(6.0, std::exp(-(w - ws) * (w - ws) / (2 * 0.05 * 0.05 * ws * ws)));
    }
    return s;
}

double OceanSpectrum::spreading(double theta) const {
    double s = settings.spreading;
    double norm = std::tgamma(s + 1) / (2 * std::sqrt(kPi) * std::tgamma(s + 0.5));
    return norm * std::pow(std::fabs(std::cos(theta / 2)), 2 * s);
}

double OceanSpectrum::spectrum2D(double kx, double kz) const {
    double k = std::sqrt(kx * kx + kz * kz);
    if (!(k > 1e-6)) return 0;
    double w = std::sqrt(kGravity * k);
    double dwdk = kGravity / (2 * w);
    double theta = std::atan2(kx, kz) - settings.windDirectionDeg * kDeg;
    double l = 0.002;
    return jonswap(w) * dwdk / k * spreading(theta) * std::exp(-k * k * l * l);
}

Vec3d OceanSpectrum::referenceDisplacement(double x, double z, double time, int cascade) const {
    double t = std::fmod(time, kOceanRepeatPeriod);
    Vec3d out{};
    double lam = settings.choppiness;
    for (int ci = 0; ci < int(cascades.size()); ++ci) {
        if (cascade >= 0 && cascade != ci) continue;
        const auto& c = cascades[std::size_t(ci)];
        double dk = 2 * kPi / c.L;
        for (int y = 0; y < N; ++y)
            for (int xi = 0; xi < N; ++xi) {
                std::size_t i = std::size_t(y) * std::size_t(N) + std::size_t(xi);
                const float* h0 = &c.h0[i * 4];
                if (h0[0] == 0 && h0[1] == 0 && h0[2] == 0 && h0[3] == 0) continue;
                double w = c.omega[i];
                double kx = double(xi - N / 2) * dk, kz = double(y - N / 2) * dk;
                double k = std::sqrt(kx * kx + kz * kz);
                double cw = std::cos(w * t), sw = std::sin(w * t);
                double hr = double(h0[0]) * cw - double(h0[1]) * sw + double(h0[2]) * cw + double(h0[3]) * sw;
                double hi = double(h0[0]) * sw + double(h0[1]) * cw - double(h0[2]) * sw + double(h0[3]) * cw;
                double ph = kx * x + kz * z, cp = std::cos(ph), sp = std::sin(ph);
                out.y += hr * cp - hi * sp;
                double im = hr * sp + hi * cp;
                out.x += lam * kx / k * im;
                out.z += lam * kz / k * im;
            }
    }
    return out;
}

// ---------------------------------------------------------------- CPU evolution + FFT (mirror of ocean.slang)

namespace {
struct C2 { float x, y; };
inline C2 cmul(C2 a, C2 b) { return {a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x}; }
inline C2 cadd(C2 a, C2 b) { return {a.x + b.x, a.y + b.y}; }
inline C2 csub(C2 a, C2 b) { return {a.x - b.x, a.y - b.y}; }
inline C2 cscale(C2 a, float s) { return {a.x * s, a.y * s}; }
inline C2 cpack(C2 a, C2 b) { return {a.x - b.y, a.y + b.x}; }
inline uint32_t bitrev(uint32_t e, int logN) {
    uint32_t r = 0;
    for (int i = 0; i < logN; ++i) r |= ((e >> i) & 1u) << (logN - 1 - i);
    return r;
}
void specAt(const OceanCascadeSpectrum& c, int N, float L, float time, int x, int y, C2 out[4]) {
    const float twoPi = 6.28318548202514648f;   // float(2 * pi), as the shader constant folds
    std::size_t idx = std::size_t(y) * std::size_t(N) + std::size_t(x);
    float kx = twoPi * (float(x) - float(N / 2)) / L, kz = twoPi * (float(y) - float(N / 2)) / L;
    float kl = std::sqrt(kx * kx + kz * kz);
    float knx = kl > 1e-6f ? kx / kl : 0.0f, knz = kl > 1e-6f ? kz / kl : 0.0f;
    const float* hv = &c.h0[idx * 4];
    float ph = c.omega[idx] * time;
    float cs = float(std::cos(double(ph))), sn = float(std::sin(double(ph)));
    C2 h = cadd(cmul({hv[0], hv[1]}, {cs, sn}), cmul({hv[2], hv[3]}, {cs, -sn}));
    C2 ih{-h.y, h.x};
    C2 hDx = cscale(ih, -knx), hDz = cscale(ih, -knz), hHx = cscale(ih, kx), hHz = cscale(ih, kz);
    float inv = kl > 1e-6f ? 1.0f / kl : 0.0f;
    out[0] = cpack(h, hDx);
    out[1] = cpack(hDz, hHx);
    out[2] = cpack(hHz, cscale(h, kx * kx * inv));
    out[3] = cpack(cscale(h, kz * kz * inv), cscale(h, kx * kz * inv));
}
void butterflies(C2* buf, const C2* tw, int N, int logN) {
    for (int s = 1; s <= logN; ++s) {
        int m = 1 << s, hm = m >> 1;
        for (int b = 0; b < N / 2; ++b) {
            int j = b & (hm - 1);
            int i0 = (b >> (s - 1)) * m + j, i1 = i0 + hm;
            C2 w = tw[j << (logN - s)];
            for (int f = 0; f < 4; ++f) {
                C2 a = buf[i0 * 4 + f], c = cmul(buf[i1 * 4 + f], w);
                buf[i0 * 4 + f] = cadd(a, c); buf[i1 * 4 + f] = csub(a, c);
            }
        }
    }
}
} // namespace

struct OceanGPUParams {
    uint32_t N, logN, cascades, pad0;
    float L[4];
    float time, choppy, dt, foamDecay;
    float foamThreshold, foamGain, pad1, pad2;
};
static_assert(sizeof(OceanGPUParams) == 64);

OceanSimulation::OceanSimulation(const OceanSettings& s, OceanDevice device) : spectrum_(s) {
    const int N = spectrum_.N, C = cascades();
    std::size_t n = std::size_t(N) * std::size_t(N) * std::size_t(C);
    for (auto& set : sets_) { set.disp.assign(n * 4, 0.0f); set.deriv.assign(n * 4, 0.0f); }
    foam_.assign(n, 0.0f);
    twiddles_.resize(std::size_t(std::max(1, N / 2)) * 2);
    for (int k = 0; k < std::max(1, N / 2); ++k) {
        double a = 2 * kPi * double(k) / double(N);
        twiddles_[std::size_t(k) * 2] = float(std::cos(a)); twiddles_[std::size_t(k) * 2 + 1] = float(std::sin(a));
    }
    if (device != OceanDevice::CPU) {
        std::string err;
        std::vector<float> d, v, f;
        gpu_ = computeGPU(0, 0, d, v, f, nullptr, &err);
        if (!gpu_ && device == OceanDevice::GPU) std::fprintf(stderr, "[Water] GPU ocean unavailable (%s); using CPU\n", err.c_str());
        std::fill(foam_.begin(), foam_.end(), 0.0f);
        if (gpu_) { std::lock_guard<std::mutex> lk(env::computeMutex()); if (auto* c = gpu::sharedCompute()) c->fill(gFoam_, 0); }
    }
}

OceanSimulation::~OceanSimulation() {
    wait();
    releaseGPU();
}

void OceanSimulation::releaseGPU() {
    std::lock_guard<std::mutex> lk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c) return;
    for (int* h : {&gH0_, &gOmega_, &gSpec_, &gTw_, &gFoam_, &gDisp_, &gDeriv_}) { if (*h) c->destroyBuffer(*h); *h = 0; }
}

void OceanSimulation::computeCPU(double time, double dt, std::vector<float>& disp, std::vector<float>& deriv, std::vector<float>& foam) const {
    const int N = spectrum_.N, C = int(spectrum_.cascades.size());
    int logN = 0; while ((1 << logN) < N) ++logN;
    std::size_t nn = std::size_t(N) * std::size_t(N);
    disp.resize(nn * std::size_t(C) * 4); deriv.resize(nn * std::size_t(C) * 4);
    if (foam.size() != nn * std::size_t(C)) foam.assign(nn * std::size_t(C), 0.0f);
    std::vector<C2> spec(nn * std::size_t(C) * 4);
    const C2* tw = reinterpret_cast<const C2*>(twiddles_.data());
    float t = float(std::fmod(time, kOceanRepeatPeriod));
    // A: rows (spectrum straight into bit-reversed order, inverse FFT)
    jobs::JobSystem::shared().parallelFor(N * C, 4, [&](int a, int b) {
        std::vector<C2> buf(std::size_t(N) * 4);
        for (int line = a; line < b; ++line) {
            int c = line / N, y = line % N;
            const auto& cs = spectrum_.cascades[std::size_t(c)];
            for (int e = 0; e < N; ++e) {
                C2 v[4]; specAt(cs, N, float(cs.L), t, e, y, v);
                uint32_t r = bitrev(uint32_t(e), logN);
                for (int f = 0; f < 4; ++f) buf[r * 4 + uint32_t(f)] = v[f];
            }
            butterflies(buf.data(), tw, N, logN);
            std::copy(buf.begin(), buf.end(), spec.begin() + std::ptrdiff_t((std::size_t(c) * nn + std::size_t(y) * std::size_t(N)) * 4));
        }
    }, "ocean.rows");
    // B: columns + finalize
    float decay = float(std::exp(-dt / std::max(double(foamDecay), 1e-3)));
    float lam = float(spectrum_.settings.choppiness);
    jobs::JobSystem::shared().parallelFor(N * C, 4, [&](int a, int b) {
        std::vector<C2> buf(std::size_t(N) * 4);
        for (int line = a; line < b; ++line) {
            int c = line / N, x = line % N;
            for (int e = 0; e < N; ++e) {
                std::size_t i = std::size_t(c) * nn + std::size_t(e) * std::size_t(N) + std::size_t(x);
                uint32_t r = bitrev(uint32_t(e), logN);
                for (int f = 0; f < 4; ++f) buf[r * 4 + uint32_t(f)] = spec[i * 4 + std::size_t(f)];
            }
            butterflies(buf.data(), tw, N, logN);
            for (int y = 0; y < N; ++y) {
                std::size_t idx = std::size_t(c) * nn + std::size_t(y) * std::size_t(N) + std::size_t(x);
                float sg = ((x + y) & 1) ? -1.0f : 1.0f;
                C2 v0 = cscale(buf[std::size_t(y) * 4 + 0], sg), v1 = cscale(buf[std::size_t(y) * 4 + 1], sg);
                C2 v2 = cscale(buf[std::size_t(y) * 4 + 2], sg), v3 = cscale(buf[std::size_t(y) * 4 + 3], sg);
                float hgt = v0.x, dx = v0.y * lam, dz = v1.x * lam, hx = v1.y, hz = v2.x;
                float dxx = v2.y * lam, dzz = v3.x * lam, dxz = v3.y * lam;
                float J = (1.0f + dxx) * (1.0f + dzz) - dxz * dxz;
                float fo = std::max(foam[idx] * decay, std::min(1.0f, std::max(0.0f, (foamThreshold - J) * foamGain)));
                foam[idx] = fo;
                float* d = &disp[idx * 4]; d[0] = dx; d[1] = hgt; d[2] = dz; d[3] = J;
                float* g = &deriv[idx * 4]; g[0] = hx; g[1] = hz; g[2] = dxx; g[3] = dzz;
            }
        }
    }, "ocean.cols");
}

bool OceanSimulation::computeGPU(double time, double dt, std::vector<float>& disp, std::vector<float>& deriv, std::vector<float>& foam,
                                 double* gpuMs, std::string* err) {
    std::lock_guard<std::mutex> lk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c) { if (err) *err = "no GPU compute device"; return false; }
    const int N = spectrum_.N, C = cascades();
    if (N > 512 || (N & (N - 1)) || C > 4) { if (err) *err = "ocean N must be a power of two <= 512 and <= 4 cascades"; return false; }
    std::size_t nn = std::size_t(N) * std::size_t(N), n = nn * std::size_t(C);
    if (!kRow_) {
        kRow_ = env::loadKernel(*c, "ocean", "oceanSpecRowFFT", 256, 1, 1, err);
        kCol_ = env::loadKernel(*c, "ocean", "oceanColFFTFinalize", 256, 1, 1, err);
        if (!kRow_ || !kCol_) return false;
        std::vector<float> h0, om;
        for (auto& cs : spectrum_.cascades) { h0.insert(h0.end(), cs.h0.begin(), cs.h0.end()); om.insert(om.end(), cs.omega.begin(), cs.omega.end()); }
        gH0_ = c->createBuffer(h0.size() * 4, h0.data());
        gOmega_ = c->createBuffer(om.size() * 4, om.data());
        gSpec_ = c->createBuffer(n * 32);
        gTw_ = c->createBuffer(twiddles_.size() * 4, twiddles_.data());
        gFoam_ = c->createBuffer(n * 4);
        gDisp_ = c->createBuffer(n * 16);
        gDeriv_ = c->createBuffer(n * 16);
        if (!gH0_ || !gOmega_ || !gSpec_ || !gTw_ || !gFoam_ || !gDisp_ || !gDeriv_) { if (err) *err = "GPU buffers: " + c->lastError(); return false; }
    }
    int logN = 0; while ((1 << logN) < N) ++logN;
    OceanGPUParams P{};
    P.N = uint32_t(N); P.logN = uint32_t(logN); P.cascades = uint32_t(C);
    for (int i = 0; i < 4; ++i) P.L[i] = i < C ? float(spectrum_.cascades[std::size_t(i)].L) : 1.0f;
    P.time = float(std::fmod(time, kOceanRepeatPeriod)); P.choppy = float(spectrum_.settings.choppiness); P.dt = float(dt);
    P.foamDecay = foamDecay; P.foamThreshold = foamThreshold; P.foamGain = foamGain;
    int bufs[] = {gH0_, gOmega_, gSpec_, gTw_, gFoam_, gDisp_, gDeriv_};
    c->begin();
    bool ok = c->dispatch(kRow_, &P, sizeof P, bufs, 7, N, C, 1) && c->dispatch(kCol_, &P, sizeof P, bufs, 7, N, C, 1);
    double ms = c->end(true);
    if (!ok) { if (err) *err = c->lastError(); return false; }
    if (gpuMs) *gpuMs = ms;
    disp.resize(n * 4); deriv.resize(n * 4); foam.resize(n);
    if (!c->download(gDisp_, disp.data(), n * 16) || !c->download(gDeriv_, deriv.data(), n * 16) || !c->download(gFoam_, foam.data(), n * 4)) {
        if (err) *err = "download: " + c->lastError();
        return false;
    }
    return true;
}

void OceanSimulation::run(double time) {
    auto t0 = std::chrono::steady_clock::now();
    double dt;
    int idx;
    {
        std::lock_guard<std::mutex> lk(mutex_);
        dt = lastSubmitTime_ >= 0 ? std::max(0.0, std::min(time - lastSubmitTime_, 0.25)) : 0;
        lastSubmitTime_ = time;
        idx = writeIndex_;
    }
    Set& s = sets_[std::size_t(idx)];
    bool done = false;
    if (gpu_) {
        std::string err;
        done = computeGPU(time, dt, s.disp, s.deriv, foam_, nullptr, &err);
        if (!done) { std::fprintf(stderr, "[Water] GPU ocean failed (%s); falling back to CPU\n", err.c_str()); gpu_ = false; }
    }
    if (!done) computeCPU(time, dt, s.disp, s.deriv, foam_);
    s.time = time;
    {
        std::lock_guard<std::mutex> lk(mutex_);
        int v = published_.load();
        int latest = (v & 0xff) - 1;
        published_.store((idx + 1) | ((latest + 1) << 8), std::memory_order_release);
        writeIndex_ = (idx + 1) % int(sets_.size());
    }
    lastMs_ = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

void OceanSimulation::update(double time) {
    wait();
    run(time);
}

bool OceanSimulation::submit(double time) {
    bool expected = false;
    if (!inFlight_.compare_exchange_strong(expected, true)) return false;
    {
        std::lock_guard<std::mutex> lk(mutex_);
        if (time == lastSubmitTime_) { inFlight_ = false; return false; }
    }
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread([this, time] { run(time); inFlight_ = false; });
    return true;
}

void OceanSimulation::wait() {
    if (worker_.joinable()) worker_.join();
}

double OceanSimulation::latestTime() const {
    int v = published_.load(std::memory_order_acquire);
    int l = (v & 0xff) - 1;
    return l >= 0 ? sets_[std::size_t(l)].time : -1;
}

bool OceanSimulation::views(OceanView& latest, OceanView* previous) const {
    int v = published_.load(std::memory_order_acquire);
    int l = (v & 0xff) - 1, p = (v >> 8) - 1;
    if (l < 0) return false;
    auto make = [&](const Set& s, OceanView& o) {
        o.disp = s.disp.data(); o.deriv = s.deriv.data(); o.N = spectrum_.N; o.cascades = cascades(); o.time = s.time;
        for (int i = 0; i < 4; ++i) {
            o.Ls[i] = i < o.cascades ? spectrum_.cascades[std::size_t(i)].L : 1.0;
            o.texelsPerMetre[i] = double(o.N) / o.Ls[i];
        }
    };
    make(sets_[std::size_t(l)], latest);
    if (previous) { if (p >= 0) make(sets_[std::size_t(p)], *previous); else *previous = OceanView{}; }
    return true;
}

// ---------------------------------------------------------------- sampling

namespace {
inline void bilinear(const float* p, int N, double u, double v, double out[4]) {
    double fu = std::floor(u), fv = std::floor(v), tx = u - fu, ty = v - fv;
    int x0 = int(int64_t(fu) & (N - 1)), y0 = int(int64_t(fv) & (N - 1)), x1 = (x0 + 1) & (N - 1), y1 = (y0 + 1) & (N - 1);
    const float *a = p + (std::size_t(y0) * std::size_t(N) + std::size_t(x0)) * 4, *b = p + (std::size_t(y0) * std::size_t(N) + std::size_t(x1)) * 4;
    const float *c = p + (std::size_t(y1) * std::size_t(N) + std::size_t(x0)) * 4, *d = p + (std::size_t(y1) * std::size_t(N) + std::size_t(x1)) * 4;
    for (int k = 0; k < 4; ++k) {
        double r0 = double(a[k]) * (1 - tx) + double(b[k]) * tx, r1 = double(c[k]) * (1 - tx) + double(d[k]) * tx;
        out[k] = r0 * (1 - ty) + r1 * ty;
    }
}
inline void catmull(const float* p, int N, double u, double v, double out[4]) {
    double fu = std::floor(u), fv = std::floor(v), tx = u - fu, ty = v - fv;
    int64_t bx = int64_t(fu), by = int64_t(fv);
    auto w = [](double t, double o[4]) {
        double t2 = t * t, t3 = t2 * t;
        o[0] = -0.5 * t3 + t2 - 0.5 * t; o[1] = 1.5 * t3 - 2.5 * t2 + 1; o[2] = -1.5 * t3 + 2 * t2 + 0.5 * t; o[3] = 0.5 * t3 - 0.5 * t2;
    };
    double wx[4], wy[4]; w(tx, wx); w(ty, wy);
    for (int k = 0; k < 4; ++k) out[k] = 0;
    for (int j = 0; j < 4; ++j) {
        int y = int((by + j - 1) & (N - 1));
        double row[4] = {0, 0, 0, 0};
        for (int i = 0; i < 4; ++i) {
            const float* f = p + (std::size_t(y) * std::size_t(N) + std::size_t((bx + i - 1) & (N - 1))) * 4;
            for (int k = 0; k < 4; ++k) row[k] += double(f[k]) * wx[i];
        }
        for (int k = 0; k < 4; ++k) out[k] += row[k] * wy[j];
    }
}
} // namespace

void OceanView::displacement(double x, double z, bool cubic, double out[4]) const {
    out[0] = out[1] = out[2] = out[3] = 0;
    std::size_t NN = std::size_t(N) * std::size_t(N);
    for (int c = 0; c < cascades; ++c) {
        double k = texelsPerMetre[c], s[4];
        if (cubic) catmull(disp + std::size_t(c) * NN * 4, N, x * k, z * k, s);
        else bilinear(disp + std::size_t(c) * NN * 4, N, x * k, z * k, s);
        s[3] -= 1;
        for (int i = 0; i < 4; ++i) out[i] += s[i];
    }
}

void OceanView::derivatives(double x, double z, double out[4]) const {
    out[0] = out[1] = out[2] = out[3] = 0;
    std::size_t NN = std::size_t(N) * std::size_t(N);
    for (int c = 0; c < cascades; ++c) {
        double k = texelsPerMetre[c], s[4];
        bilinear(deriv + std::size_t(c) * NN * 4, N, x * k, z * k, s);
        for (int i = 0; i < 4; ++i) out[i] += s[i];
    }
}

double OceanView::height(double x, double z, int iterations, bool cubic) const {
    double px = x, pz = z, d[4];
    for (int i = 0; i < iterations; ++i) { displacement(px, pz, cubic, d); px = x - d[0]; pz = z - d[2]; }
    displacement(px, pz, cubic, d);
    return d[1];
}

} // namespace pw::water
