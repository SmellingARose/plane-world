// Real-world elevation (AWS terrarium tiles) and heightmap import/export: port of Sources/Terrain/TerrainDEM.swift
// and HeightmapImport.swift.
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <thread>
#include "pw/env/codec.h"
#include "pw/env/terrain.h"

namespace pw::terrain {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kDeg = kPi / 180;
}

std::string TileID::str() const { return std::to_string(z) + "/" + std::to_string(x) + "/" + std::to_string(y); }

namespace terrarium {
std::string url(const TileID& t) {
    return "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/" + std::to_string(t.z) + "/" + std::to_string(t.x) + "/" + std::to_string(t.y) + ".png";
}
std::string cachePath(const TileID& t) {
    namespace fs = std::filesystem;
    return (env::fsPath(env::cacheDirectory()) / "terrarium" / std::to_string(t.z) / std::to_string(t.x) / (std::to_string(t.y) + ".png")).string();
}
Vec2d tileCoord(double lat, double lon, int z) {
    double n = std::pow(2.0, double(z));
    double la = std::min(std::max(lat, -85.05112878), 85.05112878) * kDeg;
    return {(lon + 180) / 360 * n, (1 - std::log(std::tan(la) + 1 / std::cos(la)) / kPi) / 2 * n};
}
void latLon(const Vec2d& t, int z, double& lat, double& lon) {
    double n = std::pow(2.0, double(z));
    lon = t.x / n * 360 - 180;
    lat = std::atan(std::sinh(kPi * (1 - 2 * t.y / n))) / kDeg;
}
double metersPerPixel(double lat, int z) { return 2 * kPi * 6378137 * std::cos(lat * kDeg) / (double(kTileSize) * std::pow(2.0, double(z))); }
void encode(float h, uint8_t& r, uint8_t& g, uint8_t& b) {
    double v = double(h) + 32768;
    auto clampU8 = [](long x) { return uint8_t(x < 0 ? 0 : (x > 255 ? 255 : x)); };
    r = clampU8(long(v / 256));
    g = clampU8(long(v) - long(r) * 256);
    b = clampU8(long(std::floor((v - std::floor(v)) * 256)));
}
bool decodePNG(const uint8_t* data, std::size_t n, int& w, int& h, std::vector<float>& heights) {
    std::vector<uint8_t> rgba;
    if (!env::decodeRGBA8(data, n, w, h, rgba)) return false;
    heights.resize(std::size_t(w) * std::size_t(h));
    for (std::size_t i = 0; i < heights.size(); ++i) heights[i] = decode(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
    return true;
}
} // namespace terrarium

RealWorldRegion::RealWorldRegion(double lat, double lon, int z, int r)
    : latitude(lat), longitude(lon), zoom(std::max(1, std::min(15, z))), radiusTiles(std::max(0, std::min(6, r))) {}

void RealWorldRegion::firstTile(int& x, int& y) const {
    Vec2d c = centerTileCoord();
    x = int(std::floor(c.x)) - radiusTiles; y = int(std::floor(c.y)) - radiusTiles;
}

std::vector<TileID> RealWorldRegion::tiles() const {
    int x0, y0; firstTile(x0, y0);
    int n = tilesPerSide(), maxT = 1 << zoom;
    std::vector<TileID> out;
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i)
            if (y0 + j >= 0 && y0 + j < maxT) out.push_back({zoom, ((x0 + i) % maxT + maxT) % maxT, y0 + j});
    Vec2d c = centerTileCoord();
    std::stable_sort(out.begin(), out.end(), [&](const TileID& a, const TileID& b) {
        double ax = a.x + 0.5 - c.x, ay = a.y + 0.5 - c.y, bx = b.x + 0.5 - c.x, by = b.y + 0.5 - c.y;
        return ax * ax + ay * ay < bx * bx + by * by;
    });
    return out;
}

Vec2d RealWorldRegion::fieldOrigin() const {
    int x0, y0; firstTile(x0, y0);
    Vec2d c = centerTileCoord();
    double ts = terrarium::kTileSize, mpp = metersPerPixel();
    return {(double(x0) * ts - c.x * ts) * mpp, (double(y0) * ts - c.y * ts) * mpp};
}

void RealWorldRegion::sampleOffset(const TileID& t, int& ox, int& oy) const {
    int x0, y0; firstTile(x0, y0);
    int maxT = 1 << zoom;
    int dx = t.x - x0;
    if (dx < 0) dx += maxT;
    if (dx >= tilesPerSide()) dx -= maxT;
    ox = dx * terrarium::kTileSize; oy = (t.y - y0) * terrarium::kTileSize;
}

void RealWorldRegion::latLon(double x, double z, double& lat, double& lon) const {
    Vec2d c = centerTileCoord();
    double ts = terrarium::kTileSize, mpp = metersPerPixel();
    Vec2d px{c.x * ts + x / mpp, c.y * ts + z / mpp};
    terrarium::latLon({px.x / ts, px.y / ts}, zoom, lat, lon);
}

Vec2d RealWorldRegion::worldXZ(double lat, double lon) const {
    Vec2d t = terrarium::tileCoord(lat, lon, zoom), c = centerTileCoord();
    double s = double(terrarium::kTileSize) * metersPerPixel();
    return {(t.x - c.x) * s, (t.y - c.y) * s};
}

// ---------------------------------------------------------------- fetcher

struct DEMTileFetcher::Impl {
    std::mutex m;
    std::condition_variable cv;
    std::deque<std::pair<TileID, Completion>> queue;
    std::vector<std::thread> threads;
    bool stop = false;
    double timeout = 20;

    Result load(const TileID& t) {
        Result r;
        std::string cache = terrarium::cachePath(t);
        std::vector<uint8_t> bytes;
        int w = 0, h = 0;
        if (env::readBinaryFile(cache, bytes)) {
            if (terrarium::decodePNG(bytes.data(), bytes.size(), w, h, r.heights) && w == terrarium::kTileSize && h == terrarium::kTileSize) {
                r.ok = true; r.fromCache = true; return r;
            }
            std::error_code ec; std::filesystem::remove(env::fsPath(cache), ec);
        }
        int status = 0; std::string err;
        if (!env::httpGet(terrarium::url(t), timeout, bytes, status, err)) { r.error = "network: " + err; return r; }
        if (status != 200) { r.error = "HTTP " + std::to_string(status); return r; }
        if (!terrarium::decodePNG(bytes.data(), bytes.size(), w, h, r.heights) || w != terrarium::kTileSize || h != terrarium::kTileSize) {
            r.error = "decode"; r.heights.clear(); return r;
        }
        env::writeBinaryFile(cache, bytes);
        r.ok = true;
        return r;
    }
    void worker() {
        for (;;) {
            std::pair<TileID, Completion> job;
            {
                std::unique_lock<std::mutex> lk(m);
                cv.wait(lk, [&] { return stop || !queue.empty(); });
                if (stop && queue.empty()) return;
                job = std::move(queue.front());
                queue.pop_front();
            }
            Result r = load(job.first);
            if (job.second) job.second(job.first, std::move(r));
        }
    }
};

DEMTileFetcher::DEMTileFetcher(int ioThreads, double timeoutSeconds) : impl_(std::make_unique<Impl>()) {
    impl_->timeout = timeoutSeconds;
    for (int i = 0; i < std::max(1, ioThreads); ++i) impl_->threads.emplace_back([this] { impl_->worker(); });
}
DEMTileFetcher::~DEMTileFetcher() {
    { std::lock_guard<std::mutex> lk(impl_->m); impl_->stop = true; }
    impl_->cv.notify_all();
    for (auto& t : impl_->threads) t.join();
}
DEMTileFetcher& DEMTileFetcher::shared() { static DEMTileFetcher f; return f; }

void DEMTileFetcher::fetch(const TileID& t, Completion done) {
    { std::lock_guard<std::mutex> lk(impl_->m); impl_->queue.emplace_back(t, std::move(done)); }
    impl_->cv.notify_one();
}

DEMTileFetcher::Result DEMTileFetcher::fetchSync(const TileID& t, double timeoutSeconds) {
    struct Box { std::mutex m; std::condition_variable cv; bool done = false; Result r; };
    auto box = std::make_shared<Box>();
    fetch(t, [box](const TileID&, Result r) { std::lock_guard<std::mutex> lk(box->m); box->r = std::move(r); box->done = true; box->cv.notify_all(); });
    std::unique_lock<std::mutex> lk(box->m);
    if (!box->cv.wait_for(lk, std::chrono::duration<double>(timeoutSeconds), [&] { return box->done; })) { Result r; r.error = "timeout"; return r; }
    return box->r;
}

// ---------------------------------------------------------------- heightmaps

static float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }

bool loadHeightmap(const std::string& path, HeightmapImage& out, std::string& err) {
    namespace fs = std::filesystem;
    std::string ext = env::fsPath(path).extension().string();
    for (auto& c : ext) c = char(std::tolower((unsigned char)c));
    std::vector<uint8_t> bytes;
    if (!env::readBinaryFile(path, bytes)) { err = "cannot read " + path; return false; }
    if (ext == ".r16" || ext == ".raw") {
        std::size_t n = bytes.size() / 2;
        int side = int(std::lround(std::sqrt(double(n))));
        if (std::size_t(side) * std::size_t(side) != n || side < 2) { err = "raw heightmap must be square 16-bit little-endian"; return false; }
        out.width = out.height = side;
        out.values.resize(n);
        for (std::size_t i = 0; i < n; ++i) out.values[i] = float(uint16_t(bytes[i * 2] | (bytes[i * 2 + 1] << 8))) / 65535;
        return true;
    }
    env::Image img;
    if (!env::decodeImage(bytes.data(), bytes.size(), img, &err)) { err = path + ": " + err; return false; }
    out.width = img.width; out.height = img.height;
    std::size_t n = std::size_t(img.width) * std::size_t(img.height);
    out.values.resize(n);
    int c = img.channels;
    auto sample = [&](std::size_t i, int k) -> float {
        return img.bits == 16 ? float(img.u16[i * std::size_t(c) + std::size_t(k)]) / 65535 : float(img.u8[i * std::size_t(c) + std::size_t(k)]) / 255;
    };
    if (c <= 2) {
        // gray (+alpha): raw values, no colour management (Swift fast path)
        for (std::size_t i = 0; i < n; ++i) out.values[i] = sample(i, 0);
    } else {
        // colour: linear-light luminance (Rec. 709 primaries), like CoreGraphics' linear-gray conversion in Swift
        for (std::size_t i = 0; i < n; ++i) {
            float r = srgbToLinear(sample(i, 0)), g = srgbToLinear(sample(i, 1)), b = srgbToLinear(sample(i, 2));
            out.values[i] = std::min(1.0f, std::max(0.0f, 0.2126f * r + 0.7152f * g + 0.0722f * b));
        }
    }
    return true;
}

bool writeHeightmapPNG16(const std::string& path, const std::vector<float>& v, int w, int h, std::string& err) {
    std::vector<uint8_t> png;
    if (!env::encodePNG16(v, w, h, png)) { err = "PNG encode failed"; return false; }
    if (!env::writeBinaryFile(path, png)) { err = "cannot write " + path; return false; }
    return true;
}

} // namespace pw::terrain
