// terrain.* self-tests (port of Sources/Terrain/TerrainSelfTests.swift, plus GPU-vs-CPU erosion, CDLOD and
// persistence compatibility checks).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <filesystem>
#include <thread>
#include "pw/compute.h"
#include "pw/env/codec.h"
#include "pw/env/terrain.h"
#include "pw/jobs.h"
#include "pw/world/document.h"
#include "selftest_util.h"

namespace pw::terrain {
using env::st::Check;

namespace {
std::unique_ptr<TerrainSystem> smallProcedural(int size = 513, double spacing = 4, int erosion = 0, ErosionDevice dev = ErosionDevice::CPU) {
    auto t = std::make_unique<TerrainSystem>();
    ProceduralParams p;   // same as the Swift tests
    p.size = size; p.spacing = spacing; p.heightScale = 600; p.featureSize = 1500;
    p.erosionIterations = erosion; p.thermalIterations = erosion > 0 ? 20 : 0;
    t->erosionDevice = dev;
    t->generateProcedural(42, p);
    return t;
}
std::string tmpPath(const std::string& name) { return (std::filesystem::temp_directory_path() / name).string(); }
double H(const HeightField& f, int x, int y) { return f.heights[std::size_t(y) * std::size_t(f.width) + std::size_t(x)]; }
} // namespace

void registerSelfTests() {
    selftest::add("terrain.flat", [](selftest::Context& ctx) {
        Check c{ctx};
        TerrainSystem t;
        sim::RayHit h;
        c.expect(t.raycast({0, 10, 0}, {0, -1, 0}, 100, h), "ray hits flat ground");
        c.close(h.distance, 10, 1e-6, "flat ray distance");
        c.close(t.height(1234, -567), 0, 1e-12, "flat height");
        return c.ok;
    });

    selftest::add("terrain.continuity", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural();
        const HeightField& f = t->field();
        for (auto [x, y] : std::vector<std::pair<int, int>>{{0, 0}, {127, 127}, {128, 128}, {129, 300}, {512, 512}}) {
            double px = f.origin.x + x * f.spacing, pz = f.origin.y + y * f.spacing;
            c.close(t->height(px, pz), H(f, x, y), 1e-3, Check::fmt("grid sample (%d,%d)", x, y));
        }
        double maxSlope = 0;
        for (int y = 1; y < f.height - 1; ++y)
            for (int x = 1; x < f.width - 1; ++x)
                maxSlope = std::max({maxSlope, std::fabs(H(f, x + 1, y) - H(f, x, y)) / f.spacing, std::fabs(H(f, x, y + 1) - H(f, x, y)) / f.spacing});
        double step = 0.05, worst = 0;
        for (double z : {f.origin.y + 127.5 * f.spacing, f.origin.y + 300.25 * f.spacing}) {
            double prev = t->height(f.origin.x - 200, z);
            for (double x = f.origin.x - 200 + step; x < f.worldMax().x + 200; x += step) {
                double h = t->height(x, z);
                worst = std::max(worst, std::fabs(h - prev) / step);
                prev = h;
            }
        }
        c.log(Check::fmt("max sample slope %.3f, max sampled slope across seams/border %.3f", maxSlope, worst));
        c.expect(worst <= maxSlope * 1.01 + 0.05, "height continuous across tiles / border");
        double seam = 0, interior = 0;
        for (int y = 0; y < f.height; ++y) { seam = std::max(seam, std::fabs(H(f, 128, y) - H(f, 127, y))); interior = std::max(interior, std::fabs(H(f, 100, y) - H(f, 99, y))); }
        c.expect(seam < std::max(interior * 3, 2.0), "no discontinuity at generation seams");
        Vec3d n = t->normal(0, 0);
        c.close(length(n), 1, 1e-9, "unit normal");
        c.expect(n.y > 0, "normal points up");
        auto m = t->material(0, 0);
        c.close(m.weights[0] + m.weights[1] + m.weights[2] + m.weights[3], 1, 1e-3, "material weights normalised");
        return c.ok;
    });

    selftest::add("terrain.erosion", [](selftest::Context& ctx) {
        Check c{ctx};
        auto a = smallProcedural(513, 4, 0);
        auto b = smallProcedural(513, 4, 120);
        if (!b->lastErosion()) { c.expect(false, "erosion did not run"); return c.ok; }
        const auto& r = *b->lastErosion();
        const HeightField &fa = a->field(), &fb = b->field();
        bool finite = true; double sum = 0, mx = 0;
        std::size_t n = fa.base.size();
        for (std::size_t i = 0; i < n; ++i) {
            if (!std::isfinite(fb.base[i])) finite = false;
            double d = std::fabs(double(fb.base[i]) - double(fa.base[i])); sum += d; mx = std::max(mx, d);
        }
        double mean = sum / double(n);
        double minB = fa.minHeight;
        double volChange = std::fabs(r.volumeAfter - r.volumeBefore) / std::max(r.volumeBefore - minB * double(n), 1.0);
        int wet = 0; for (float m : fb.moisture) if (m > 0.5f) ++wet;
        c.log(Check::fmt("513^2 x 120 hydraulic + 20 thermal on %s: %.0f ms, mean |dh| %.2f m, max %.1f m, volume change %.2f%%, wet %.1f%%",
                         r.backend.c_str(), r.cpuMs, mean, mx, volChange * 100, 100.0 * wet / double(n)));
        c.expect(finite, "eroded heights finite");
        c.expect(mean > 0.02, "erosion changed the terrain");
        c.expect(volChange < 0.04, "mass approximately conserved");
        c.expect(wet > 0, "moisture map produced");
        return c.ok;
    });

    selftest::add("terrain.erosion-gpu-vs-cpu", [](selftest::Context& ctx) {
        Check c{ctx};
        if (!gpu::sharedCompute()) { c.log("SKIP: no GPU compute device"); return true; }
        const int W = 161, Hh = 129;
        HeightField f(W, Hh, 4.0, {0, 0});
        world::ProceduralParams p; p.size = W; p.spacing = 4; p.featureSize = 600;
        world::generateProcedural(f, 7, p);
        ErosionParams ep; ep.iterations = 48; ep.thermalIterations = 8;
        std::vector<float> bc = f.base, bg = f.base, sc, sg, mc, mg;
        auto t0 = env::st::now();
        erodeRaw(W, Hh, 4.0f, ep, ErosionDevice::CPU, bc, sc, mc);
        double cpuMs = env::st::ms(t0);
        double gpuMs = 0; std::string err;
        bool ok = erodeRaw(W, Hh, 4.0f, ep, ErosionDevice::GPU, bg, sg, mg, &gpuMs, &err);
        c.expect(ok, "GPU erosion ran: " + err);
        if (!ok) return c.ok;
        double maxB = 0, sumB = 0, maxRel = 0;
        double range = double(*std::max_element(f.base.begin(), f.base.end()) - *std::min_element(f.base.begin(), f.base.end()));
        for (std::size_t i = 0; i < bc.size(); ++i) {
            double d = std::fabs(double(bc[i]) + sc[i] - double(bg[i]) - sg[i]);
            maxB = std::max(maxB, d); sumB += d;
        }
        double erodedMean = 0;
        for (std::size_t i = 0; i < bc.size(); ++i) erodedMean += std::fabs(double(bc[i]) - double(f.base[i]));
        erodedMean /= double(bc.size());
        maxRel = maxB / std::max(range, 1.0);
        c.log(Check::fmt("161x129, 56 iterations: CPU %.1f ms, GPU %.2f ms; |CPU - GPU| max %.3g m mean %.3g m (terrain change mean %.3f m, relief %.0f m)",
                         cpuMs, gpuMs, maxB, sumB / double(bc.size()), erodedMean, range));
        // Same kernels, different float pipelines (GPU contraction / sqrt): agree to a small fraction of the change.
        c.expect(sumB / double(bc.size()) < 0.05 * std::max(erodedMean, 1e-3) + 1e-4, "GPU and CPU erosion agree on average");
        c.expect(maxRel < 0.02, "GPU and CPU erosion agree everywhere (max deviation < 2% of relief)");
        return c.ok;
    });

    selftest::add("terrain.dem-decode", [](selftest::Context& ctx) {
        Check c{ctx};
        for (float h : {-10994.0f, -1.0f, 0.0f, 0.5f, 8848.25f, 123.75f}) {
            uint8_t r, g, b; terrarium::encode(h, r, g, b);
            c.close(terrarium::decode(r, g, b), h, 1.0 / 256, Check::fmt("terrarium round trip %g", h));
        }
        c.close(terrarium::decode(128, 0, 0), 0, 0, "R=128 -> 0 m");
        Vec2d tc = terrarium::tileCoord(46.8523, -121.7603, 10);
        c.expect(int(tc.x) == 165 && int(tc.y) == 360, Check::fmt("Rainier tile z10 = %d/%d (expect 165/360)", int(tc.x), int(tc.y)));
        double lat, lon; terrarium::latLon(tc, 10, lat, lon);
        c.close(lat, 46.8523, 1e-9, "lat round trip"); c.close(lon, -121.7603, 1e-9, "lon round trip");
        RealWorldRegion reg(46.8523, -121.7603, 12, 1);
        Vec2d w = reg.worldXZ(46.8523, -121.7603);
        c.expect(std::hypot(w.x, w.y) < 1e-6, "centre maps to world origin");
        reg.latLon(1000, -1000, lat, lon);
        c.expect(lat > 46.8523 && lon > -121.7603, "+x east, -z north");
        c.close(reg.metersPerPixel(), 2 * 3.14159265358979323846 * 6378137 * std::cos(46.8523 * 3.14159265358979323846 / 180) / (256 * 4096), 1e-9, "metres per pixel");
        std::vector<uint8_t> px(256 * 256 * 4);
        for (int i = 0; i < 256 * 256; ++i) { terrarium::encode(float(i % 4000) - 200, px[std::size_t(i) * 4], px[std::size_t(i) * 4 + 1], px[std::size_t(i) * 4 + 2]); px[std::size_t(i) * 4 + 3] = 255; }
        std::vector<uint8_t> png; env::encodePNG8(px.data(), 256, 256, 4, png);
        int ww = 0, hh = 0; std::vector<float> dec;
        c.expect(terrarium::decodePNG(png.data(), png.size(), ww, hh, dec) && ww == 256 && hh == 256, "decode synthetic terrarium PNG");
        float maxErr = 0;
        for (int i = 0; i < 256 * 256 && !dec.empty(); ++i) maxErr = std::max(maxErr, std::fabs(dec[std::size_t(i)] - (float(i % 4000) - 200)));
        c.expect(maxErr == 0, Check::fmt("PNG decode exact (max err %g)", maxErr));
        auto tiles = reg.tiles();
        c.expect(tiles.size() == 9, "3x3 mosaic");
        int ox, oy; reg.sampleOffset(tiles[0], ox, oy);
        c.expect(ox == 256 && oy == 256, "nearest tile first, centred in the mosaic");
        return c.ok;
    });

    selftest::add("terrain.dem-fetch", [](selftest::Context& ctx) {
        Check c{ctx};
        TileID t{10, 165, 360};   // Mount Rainier (4392 m)
        bool cached = std::filesystem::exists(env::fsPath(terrarium::cachePath(t)));
        auto t0 = env::st::now();
        auto r = DEMTileFetcher::shared().fetchSync(t, 20);
        if (!r.ok) { c.log("SKIP (offline?): " + r.error); return true; }
        float mx = *std::max_element(r.heights.begin(), r.heights.end()), mn = *std::min_element(r.heights.begin(), r.heights.end());
        c.log(Check::fmt("tile %s (%s) in %.0f ms: min %.0f m, max %.0f m", t.str().c_str(), cached ? "disk cache" : "network", env::st::ms(t0), mn, mx));
        c.expect(mx > 3600 && mx < 4450, "Rainier summit height plausible");
        c.expect(mn > 0 && mn < 1500, "valley floor plausible");
        c.expect(std::filesystem::exists(env::fsPath(terrarium::cachePath(t))), "tile cached on disk");
        return c.ok;
    });

    selftest::add("terrain.realworld", [](selftest::Context& ctx) {
        Check c{ctx};
        TerrainSystem t;
        auto t0 = env::st::now();
        t.loadRealWorld(RealWorldRegion(46.8523, -121.7603, 12, 1), true, 20);
        while (t.loadingProgress() < 1 && env::st::ms(t0) < 40000) { t.update({}, 0.016); std::this_thread::sleep_for(std::chrono::milliseconds(20)); }
        t.applyPendingTiles(1 << 20);
        if (t.tilesLoaded() == 0) { c.log(Check::fmt("SKIP (offline?): no tiles loaded, %d failed", t.tilesFailed())); return true; }
        Vec2d s = *t.worldXZ(46.8523, -121.7603);
        double peak = 0;
        for (double dz = -600; dz <= 600; dz += 20) for (double dx = -600; dx <= 600; dx += 20) peak = std::max(peak, t.height(s.x + dx, s.y + dz));
        const HeightField& f = t.field();
        c.log(Check::fmt("%d/%d tiles in %.0f ms, %.1f m/px, field %d^2, heights %.0f..%.0f m, summit peak %.0f m", t.tilesLoaded(), t.tilesRequested(),
                         env::st::ms(t0), f.spacing, f.width, f.minHeight, f.maxHeight, peak));
        c.expect(peak > 4000 && peak < 4450, "Rainier summit near world origin");
        c.expect(t.tilesLoaded() + t.tilesFailed() == t.tilesRequested(), "all tiles streamed");
        double worst = 0;
        for (int y = 0; y < f.height; y += 7)
            worst = std::max(worst, std::fabs(H(f, 256, y) - H(f, 255, y)) / std::max(1.0, std::fabs(H(f, 255, y) - H(f, 254, y)) * 3 + 20));
        c.expect(worst <= 1, "no step discontinuity at DEM tile seams");
        return c.ok;
    });

    selftest::add("terrain.raycast", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural(257, 8);
        int hits = 0;
        for (int i = 0; i < 64; ++i) {
            double a = i * 0.37;
            Vec3d o{std::cos(a) * 300, 1200, std::sin(a) * 300};
            Vec3d d = normalize(Vec3d{std::cos(a * 1.7) * 0.6, -1, std::sin(a * 2.3) * 0.6});
            sim::RayHit h;
            if (!t->raycast(o, d, 5000, h)) continue;
            ++hits;
            c.close(h.position.y, t->height(h.position.x, h.position.z), 0.05, "hit on surface");
            c.expect(length(o + d * h.distance - h.position) < 0.1, Check::fmt("hit lies on ray (off by %.3f m, t=%.1f)", length(o + d * h.distance - h.position), h.distance));
            bool clear = true;
            for (double s = 0; s < h.distance - 0.5; s += 2) { Vec3d p = o + d * s; if (p.y < t->height(p.x, p.z) - 0.01) { clear = false; break; } }
            c.expect(clear, "first hit (no earlier intersection)");
        }
        c.expect(hits == 64, Check::fmt("all downward rays hit (%d)", hits));
        sim::RayHit h;
        c.expect(!t->raycast({0, 5000, 0}, {0, 1, 0}, 1e4, h), "upward ray misses");
        return c.ok;
    });

    selftest::add("terrain.sculpt-paint", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural(257, 4);
        Vec3d ctr{10, 0, -20};
        double h0 = t->height(ctr.x, ctr.z);
        t->sculpt(SculptTool::Raise, ctr, 30, 20, 0.5);
        double h1 = t->height(ctr.x, ctr.z);
        c.close(h1 - h0, 10, 0.2, "raise by strength * dt at centre");
        const HeightField& f = t->field();
        c.close(t->height(ctr.x + 40, ctr.z), f.sampleClamped(f.base, (ctr.x + 40 - f.origin.x) / 4, (ctr.z - f.origin.y) / 4), 1e-3, "outside radius untouched");
        t->sculpt(SculptTool::Flatten, ctr, 30, 50, 1, h0);
        c.expect(std::fabs(t->height(ctr.x, ctr.z) - h0) < std::fabs(h1 - h0) * 0.5, "flatten moves toward target");
        auto rough = [&] {
            double s = 0;
            for (int j = -4; j <= 4; ++j) for (int i = -4; i <= 4; ++i) {
                double x = ctr.x + i * 4, z = ctr.z + j * 4;
                double l = 4 * t->height(x, z) - t->height(x - 4, z) - t->height(x + 4, z) - t->height(x, z - 4) - t->height(x, z + 4);
                s += l * l;
            }
            return s;
        };
        double r0 = rough();
        for (int i = 0; i < 10; ++i) t->sculpt(SculptTool::Smooth, ctr, 30, 5, 0.5);
        c.expect(rough() <= r0 + 1e-6, Check::fmt("smooth reduces variation (%.1f -> %.1f)", r0, rough()));
        t->paint(3, ctr, 20, 1, 1);
        c.expect(t->material(ctr.x, ctr.z).weights[3] > 0.9f, "painted snow at centre");
        c.expect(t->dirtyChunkCount() > 0, "edits mark GPU chunks dirty");
        // persistence round trip through JSON text
        world::TerrainSpec spec = t->makeSpec();
        c.expect(spec.params.has("edits") && spec.params.has("paint"), "edits serialised");
        world::WorldDocument doc; doc.terrain = spec;
        std::string text = json::dump(world::toJson(doc));
        c.log(Check::fmt("procedural world with edits: %zu bytes JSON", text.size()));
        auto parsed = json::parse(text);
        world::WorldDocument back; std::string err;
        c.expect(parsed.ok && world::fromJson(parsed.value, back, err), "world JSON parses: " + err);
        TerrainSystem t2;
        c.expect(t2.load(back.terrain, "", err), "reload: " + err);
        double maxErr = 0;
        for (double i = -40; i <= 40; i += 3) maxErr = std::max(maxErr, std::fabs(t2.height(ctr.x + i, ctr.z) - t->height(ctr.x + i, ctr.z)));
        c.expect(maxErr < 0.05, Check::fmt("reloaded sculpt matches (err %.4f m, Float16 deltas)", maxErr));
        c.expect(t2.material(ctr.x, ctr.z).weights[3] > 0.9f, "reloaded paint matches");
        t->clearEdits();
        c.expect(!t->hasEdits(), "clear edits");
        return c.ok;
    });

    selftest::add("terrain.edits-codec", [](selftest::Context& ctx) {
        Check c{ctx};
        // IEEE half conversions (Swift Float16 semantics: round to nearest even)
        struct HC { float f; uint16_t h; } cases[] = {{0.0f, 0x0000}, {1.0f, 0x3C00}, {-2.0f, 0xC000}, {65504.0f, 0x7BFF}, {65520.0f, 0x7C00},
                                                       {5.9604645e-8f, 0x0001}, {6.1035156e-5f, 0x0400}, {0.1f, 0x2E66}, {1.0009765625f, 0x3C01},
                                                       {1.00048828125f, 0x3C00} /* tie -> even */, {1.00146484375f, 0x3C02} /* tie -> even */};
        for (auto& k : cases) {
            uint16_t h = env::floatToHalf(k.f);
            c.expect(h == k.h, Check::fmt("half(%g) = 0x%04x (expect 0x%04x)", k.f, h, k.h));
        }
        for (uint32_t h = 0; h < 0x7C00; h += 7) c.expect(env::floatToHalf(env::halfToFloat(uint16_t(h))) == h, Check::fmt("half round trip 0x%04x", h));
        // raw DEFLATE round trip (format of NSData .zlib used by the Swift app)
        std::vector<uint8_t> raw(100000);
        for (std::size_t i = 0; i < raw.size(); ++i) raw[i] = uint8_t((i * 7) % 13 == 0 ? i : 0);
        std::vector<uint8_t> z, back;
        c.expect(env::deflateRaw(raw.data(), raw.size(), z), "deflate");
        c.expect(env::inflateRaw(z.data(), z.size(), back, raw.size()) && back == raw, "inflate round trip");
        c.expect(z.size() < raw.size() / 4, "sparse data compresses");
        c.expect(z.size() > 2 && !(z[0] == 0x78), "raw stream (no zlib header)");
        std::vector<uint8_t> junk = {1, 2, 3, 4};
        c.expect(!env::inflateRaw(junk.data(), junk.size(), back), "corrupt input rejected");
        // Generated by the Swift app's codec: (Data(repeating: 0x2A, count: 16) + (0..<48).map { $0 * 5 }) as NSData .compressed(using: .zlib)
        const uint8_t apple[] = {0xd3, 0xd2, 0x42, 0x05, 0x0c, 0xac, 0x5c, 0xfc, 0x22, 0x92, 0x72, 0xca, 0x1a, 0xba, 0x46, 0xe6, 0x36, 0x8e, 0x6e,
                                 0xde, 0x01, 0xa1, 0x51, 0xf1, 0x29, 0x99, 0x79, 0xc5, 0x15, 0xb5, 0x4d, 0xed, 0x3d, 0x13, 0xa7, 0xcd, 0x5e, 0xb0,
                                 0x74, 0xd5, 0xfa, 0x2d, 0x3b, 0xf7, 0x1d, 0x3e, 0x71, 0xf6, 0xd2, 0xf5, 0x3b, 0x0f, 0x9f, 0xbd, 0x06, 0x00};
        std::vector<uint8_t> expect(16, 0x2A);
        for (int i = 0; i < 48; ++i) expect.push_back(uint8_t(i * 5 % 256));
        c.expect(env::inflateRaw(apple, sizeof apple, back, 64) && back == expect, "inflates a stream written by the Swift app (NSData .zlib)");
        return c.ok;
    });

    selftest::add("terrain.heightmap", [](selftest::Context& ctx) {
        Check c{ctx};
        const int w = 129, h = 97;
        std::vector<float> v(std::size_t(w) * h);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) v[std::size_t(y) * w + std::size_t(x)] = float((x * 500 + y * 37) % 65536) / 65535;
        std::string path = tmpPath("pw-heightmap16.png"), err;
        c.expect(writeHeightmapPNG16(path, v, w, h, err), "write 16-bit PNG: " + err);
        HeightmapImage img;
        c.expect(loadHeightmap(path, img, err), "load: " + err);
        c.expect(img.width == w && img.height == h, "size");
        float maxErr = 0;
        for (std::size_t i = 0; i < v.size() && i < img.values.size(); ++i) maxErr = std::max(maxErr, std::fabs(img.values[i] - v[i]));
        c.expect(maxErr <= 1.0f / 65535 + 1e-7f, Check::fmt("16-bit precision preserved (err %.2f LSB)", maxErr * 65535));
        TerrainSystem t;
        c.expect(t.importHeightmap(path, 2, 1000, err), "import: " + err);
        c.close(H(t.field(), 10, 20), double(v[20 * w + 10]) * 1000, 0.02, "imported heights scaled");
        auto spec = t.makeSpec();
        c.expect(spec.kind == world::TerrainKind::Heightmap && spec.heightScale == 1000.0, "spec round trip");
        // raw 16-bit
        std::vector<uint8_t> r16(65 * 65 * 2);
        for (std::size_t i = 0; i < 65 * 65; ++i) { uint16_t q = uint16_t(i * 13); r16[i * 2] = uint8_t(q); r16[i * 2 + 1] = uint8_t(q >> 8); }
        std::string rp = tmpPath("pw-heightmap.r16");
        env::writeBinaryFile(rp, r16);
        c.expect(loadHeightmap(rp, img, err) && img.width == 65 && std::fabs(img.values[100] - float(uint16_t(1300)) / 65535) < 1e-7f, "raw .r16");
        return c.ok;
    });

    selftest::add("terrain.queries-parallel", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural(1025, 8);
        const int n = 2000000;
        std::vector<double> sums(64, 0.0);
        auto t0 = env::st::now();
        jobs::JobSystem::shared().parallelFor(64, 1, [&](int a, int b) {
            for (int k = a; k < b; ++k) {
                double acc = 0;
                for (int i = 0; i < n / 64; ++i) { double x = double((i * 7919 + k * 31) % 8000) - 4000, z = double((int64_t(i) * 104729) % 8000) - 4000; acc += t->height(x, z); }
                sums[std::size_t(k)] = acc;
            }
        });
        double dt = env::st::ms(t0);
        c.log(Check::fmt("%d height queries on %d threads: %.1f ms (%.1f M/s)", n, jobs::JobSystem::shared().threadCount(), dt, n / dt / 1e3));
        c.expect(std::all_of(sums.begin(), sums.end(), [](double s) { return std::isfinite(s); }), "finite");
        return c.ok;
    });

    selftest::add("terrain.minmax", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural(513, 8);
        const HeightField& f = t->field();
        geo::PCG32 rng(3);
        for (int k = 0; k < 200; ++k) {
            int x0 = int(rng.next32() % 500), y0 = int(rng.next32() % 500);
            int x1 = std::min(512, x0 + 1 + int(rng.next32() % 200)), y1 = std::min(512, y0 + 1 + int(rng.next32() % 200));
            float lo, hi; t->minMax().range(x0, y0, x1, y1, lo, hi);
            float blo = INFINITY, bhi = -INFINITY;
            for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) { blo = std::min(blo, float(H(f, x, y))); bhi = std::max(bhi, float(H(f, x, y))); }
            if (!(lo <= blo && hi >= bhi)) { c.expect(false, Check::fmt("pyramid range not conservative at (%d,%d)-(%d,%d)", x0, y0, x1, y1)); break; }
        }
        t->sculpt(SculptTool::Raise, {0, 0, 0}, 50, 200, 1);
        c.close(t->field().maxHeight, *std::max_element(t->field().heights.begin(), t->field().heights.end()), 1e-4, "global max follows edits");
        return c.ok;
    });

    selftest::add("terrain.lod", [](selftest::Context& ctx) {
        Check c{ctx};
        auto t = smallProcedural(1025, 8);
        TerrainLODSettings s;
        std::vector<TerrainNode> nodes;
        Vec3d cam{100, t->height(100, 100) + 50, 100};
        auto st = selectLOD(*t, s, cam, nullptr, nodes);
        c.expect(st.nodes > 0 && st.levels > 3, Check::fmt("%d nodes, %d levels", st.nodes, st.levels));
        // the selected nodes tile the root square exactly (no gaps, no overlap): areas add up and no two overlap
        double area = 0;
        for (auto& n : nodes) area += double(n.size) * n.size;
        double extent = 0;
        { double mnx = 1e30, mnz = 1e30, mxx = -1e30, mxz = -1e30;
          for (auto& n : nodes) { mnx = std::min(mnx, double(n.minX)); mnz = std::min(mnz, double(n.minZ)); mxx = std::max(mxx, double(n.minX + n.size)); mxz = std::max(mxz, double(n.minZ + n.size)); }
          extent = (mxx - mnx) * (mxz - mnz); }
        c.close(area, extent, extent * 1e-6, "nodes tile the root square");
        bool overlap = false;
        for (std::size_t i = 0; i < nodes.size() && !overlap; ++i)
            for (std::size_t j = i + 1; j < nodes.size(); ++j) {
                const auto &a = nodes[i], &b = nodes[j];
                if (a.minX < b.minX + b.size - 1e-3f && b.minX < a.minX + a.size - 1e-3f && a.minZ < b.minZ + b.size - 1e-3f && b.minZ < a.minZ + a.size - 1e-3f) { overlap = true; break; }
            }
        c.expect(!overlap, "no overlapping nodes");
        // finest nodes near the camera, coarse far away
        const TerrainNode* nearest = nullptr; double best = 1e30;
        for (auto& n : nodes) { double d = std::hypot(n.minX + n.size / 2 - cam.x, n.minZ + n.size / 2 - cam.z); if (d < best) { best = d; nearest = &n; } }
        c.expect(nearest && nearest->level == 0, "level 0 under the camera");
        for (auto& n : nodes) if (!(n.morphStart < n.morphEnd && n.minY <= n.maxY)) { c.expect(false, "morph range / height bounds"); break; }
        // frustum culling removes nodes behind the camera
        std::vector<TerrainNode> culled;
        Frustum half{};
        for (int i = 0; i < 6; ++i) { half.planes[i][0] = 0; half.planes[i][1] = 0; half.planes[i][2] = 0; half.planes[i][3] = 1; }
        half.planes[0][2] = 1; half.planes[0][3] = -cam.z;   // keep z >= cam.z
        auto st2 = selectLOD(*t, s, cam, &half, culled);
        c.expect(st2.nodes < st.nodes && st2.culled > 0, Check::fmt("frustum culls (%d -> %d nodes)", st.nodes, st2.nodes));
        std::vector<TerrainNodeGPU> gpuNodes;
        packNodes(nodes, cam, gpuNodes);
        c.expect(gpuNodes.size() == nodes.size(), "pack GPU nodes");
        c.log(Check::fmt("%d nodes (%d levels), %d after culling half space", st.nodes, st.levels, st2.nodes));
        return c.ok;
    });

    selftest::add("terrain.bake-hook", [](selftest::Context& ctx) {
        Check c{ctx};
        world::WorldDocument doc;
        doc.terrain.kind = world::TerrainKind::Procedural;
        doc.terrain.seed = 9;
        ProceduralParams p; p.size = 257; p.spacing = 8; p.erosionIterations = 30; p.thermalIterations = 5;
        doc.terrain.params = p.toJson();
        world::HeadlessWorld w; std::string err;
        world::HeadlessOptions opt;
        c.expect(world::bake(doc, "", opt, 1, w, err), "bake: " + err);
        bool eroded = std::any_of(w.notes.begin(), w.notes.end(), [](const std::string& s) { return s.find("eroded on CPU") != std::string::npos; });
        for (auto& n : w.notes) c.log("note: " + n);
        c.expect(eroded, "headless bake eroded the terrain on the CPU (deterministic)");
        world::HeadlessWorld w2;
        world::bake(doc, "", opt, 1, w2, err);
        bool same = w.terrain && w2.terrain && w.terrain->field().heights == w2.terrain->field().heights;
        c.expect(same, "headless bake is deterministic");
        return c.ok;
    });
}

} // namespace pw::terrain
