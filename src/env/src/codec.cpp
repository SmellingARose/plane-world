#include "pw/env/codec.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <zlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO_WARNINGS
#define STBI_FAILURE_USERMSG
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wsign-compare"
#elif defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4244 4245 4456 4457 4701)
#endif
#include "stb_image.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(_MSC_VER)
#pragma warning(pop)
#endif

namespace pw::env {

// ---------------------------------------------------------------- half floats

uint16_t floatToHalf(float f) {
    uint32_t x; std::memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    uint32_t absx = x & 0x7FFFFFFFu;
    if (absx >= 0x7F800000u) return uint16_t(sign | (absx > 0x7F800000u ? 0x7E00u : 0x7C00u));   // NaN / inf
    if (absx >= 0x477FF000u) return uint16_t(sign | 0x7C00u);                                       // rounds to inf
    if (absx < 0x38800000u) {                                                                        // subnormal half
        if (absx < 0x33000000u) return uint16_t(sign);                                               // < half of min subnormal
        uint32_t e = absx >> 23, m = (absx & 0x7FFFFFu) | 0x800000u;
        // value = m * 2^(e - 150); in half-subnormal units (2^-24) that is m * 2^(e - 126): shift right by 126 - e.
        uint32_t shift = 126 - e;
        uint32_t q = m >> shift, rem = m & ((1u << shift) - 1), halfway = 1u << (shift - 1);
        if (rem > halfway || (rem == halfway && (q & 1u))) ++q;
        return uint16_t(sign | q);
    }
    uint32_t e = (absx >> 23) - 112, m = absx & 0x7FFFFFu;
    uint32_t h = (e << 10) | (m >> 13);
    uint32_t rem = m & 0x1FFFu;
    if (rem > 0x1000u || (rem == 0x1000u && (h & 1u))) ++h;   // may carry into the exponent (correct)
    return uint16_t(sign | h);
}

float halfToFloat(uint16_t h) {
    uint32_t sign = uint32_t(h & 0x8000u) << 16, e = (h >> 10) & 0x1Fu, m = h & 0x3FFu, x;
    if (e == 0) {
        if (m == 0) x = sign;
        else { float f = float(m) * (1.0f / 16777216.0f); std::memcpy(&x, &f, 4); x |= sign; }
    } else if (e == 31) x = sign | 0x7F800000u | (m << 13);
    else x = sign | ((e + 112) << 23) | (m << 13);
    float f; std::memcpy(&f, &x, 4); return f;
}

// ---------------------------------------------------------------- raw deflate

bool deflateRaw(const uint8_t* data, std::size_t n, std::vector<uint8_t>& out, int level) {
    z_stream s{};
    if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return false;
    out.resize(deflateBound(&s, uLong(n)) + 16);
    s.next_in = const_cast<Bytef*>(data); s.avail_in = uInt(n);
    s.next_out = out.data(); s.avail_out = uInt(out.size());
    int r = deflate(&s, Z_FINISH);
    out.resize(s.total_out);
    deflateEnd(&s);
    return r == Z_STREAM_END;
}

bool inflateRaw(const uint8_t* data, std::size_t n, std::vector<uint8_t>& out, std::size_t expected) {
    z_stream s{};
    if (inflateInit2(&s, -15) != Z_OK) return false;
    out.assign(expected ? expected : std::max<std::size_t>(n * 4, 1024), 0);
    s.next_in = const_cast<Bytef*>(data); s.avail_in = uInt(n);
    int r = Z_OK;
    while (true) {
        if (s.total_out >= out.size()) out.resize(out.size() * 2);
        s.next_out = out.data() + s.total_out; s.avail_out = uInt(out.size() - s.total_out);
        r = inflate(&s, Z_NO_FLUSH);
        if (r == Z_STREAM_END) break;
        if (r != Z_OK && r != Z_BUF_ERROR) break;
        if (r == Z_BUF_ERROR && s.avail_in == 0) break;   // truncated input
    }
    out.resize(s.total_out);
    inflateEnd(&s);
    return r == Z_STREAM_END;
}

// ---------------------------------------------------------------- images

bool decodeImage(const uint8_t* data, std::size_t n, Image& out, std::string* err) {
    out = Image{};
    int w = 0, h = 0, c = 0;
    if (!stbi_info_from_memory(data, int(n), &w, &h, &c)) { if (err) *err = stbi_failure_reason() ? stbi_failure_reason() : "unsupported image"; return false; }
    if (stbi_is_16_bit_from_memory(data, int(n))) {
        stbi_us* p = stbi_load_16_from_memory(data, int(n), &w, &h, &c, 0);
        if (!p) { if (err) *err = stbi_failure_reason() ? stbi_failure_reason() : "decode failed"; return false; }
        out.u16.assign(p, p + std::size_t(w) * std::size_t(h) * std::size_t(c));
        stbi_image_free(p);
        out.bits = 16;
    } else {
        stbi_uc* p = stbi_load_from_memory(data, int(n), &w, &h, &c, 0);
        if (!p) { if (err) *err = stbi_failure_reason() ? stbi_failure_reason() : "decode failed"; return false; }
        out.u8.assign(p, p + std::size_t(w) * std::size_t(h) * std::size_t(c));
        stbi_image_free(p);
        out.bits = 8;
    }
    out.width = w; out.height = h; out.channels = c;
    return true;
}

bool loadImageFile(const std::string& path, Image& out, std::string* err) {
    std::vector<uint8_t> bytes;
    if (!readBinaryFile(path, bytes)) { if (err) *err = "cannot read " + path; return false; }
    return decodeImage(bytes.data(), bytes.size(), out, err);
}

bool decodeRGBA8(const uint8_t* data, std::size_t n, int& w, int& h, std::vector<uint8_t>& rgba) {
    int c = 0;
    stbi_uc* p = stbi_load_from_memory(data, int(n), &w, &h, &c, 4);
    if (!p) return false;
    rgba.assign(p, p + std::size_t(w) * std::size_t(h) * 4);
    stbi_image_free(p);
    return true;
}

static void put32(std::vector<uint8_t>& v, uint32_t x) { v.push_back(uint8_t(x >> 24)); v.push_back(uint8_t(x >> 16)); v.push_back(uint8_t(x >> 8)); v.push_back(uint8_t(x)); }
static void chunk(std::vector<uint8_t>& png, const char* type, const std::vector<uint8_t>& data) {
    put32(png, uint32_t(data.size()));
    std::size_t start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), data.begin(), data.end());
    uLong crc = crc32(0L, png.data() + start, uInt(png.size() - start));
    put32(png, uint32_t(crc));
}
static bool writePNG(const std::vector<uint8_t>& raw, int w, int h, int bitDepth, int colorType, std::vector<uint8_t>& png) {
    png = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    std::vector<uint8_t> ihdr;
    put32(ihdr, uint32_t(w)); put32(ihdr, uint32_t(h));
    ihdr.push_back(uint8_t(bitDepth)); ihdr.push_back(uint8_t(colorType)); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk(png, "IHDR", ihdr);
    uLongf bound = compressBound(uLong(raw.size()));
    std::vector<uint8_t> z(bound);
    if (compress2(z.data(), &bound, raw.data(), uLong(raw.size()), 6) != Z_OK) return false;
    z.resize(bound);
    chunk(png, "IDAT", z);
    chunk(png, "IEND", {});
    return true;
}

bool encodePNG16(const std::vector<float>& values, int w, int h, std::vector<uint8_t>& png) {
    if (w <= 0 || h <= 0 || values.size() < std::size_t(w) * std::size_t(h)) return false;
    std::vector<uint8_t> raw;
    raw.reserve(std::size_t(h) * (std::size_t(w) * 2 + 1));
    for (int y = 0; y < h; ++y) {
        raw.push_back(0);   // filter: none
        for (int x = 0; x < w; ++x) {
            double v = double(values[std::size_t(y) * std::size_t(w) + std::size_t(x)]) * 65535.0;
            long q = std::lround(v);
            uint16_t u = uint16_t(q < 0 ? 0 : (q > 65535 ? 65535 : q));
            raw.push_back(uint8_t(u >> 8)); raw.push_back(uint8_t(u));
        }
    }
    return writePNG(raw, w, h, 16, 0, png);
}

bool encodePNG8(const uint8_t* px, int w, int h, int channels, std::vector<uint8_t>& png) {
    if (channels != 1 && channels != 4) return false;
    std::vector<uint8_t> raw;
    std::size_t row = std::size_t(w) * std::size_t(channels);
    raw.reserve(std::size_t(h) * (row + 1));
    for (int y = 0; y < h; ++y) { raw.push_back(0); raw.insert(raw.end(), px + std::size_t(y) * row, px + std::size_t(y + 1) * row); }
    return writePNG(raw, w, h, 8, channels == 4 ? 6 : 0, png);
}

// ---------------------------------------------------------------- files

bool readBinaryFile(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(fsPath(path), std::ios::binary);
    if (!f) return false;
    f.seekg(0, std::ios::end);
    std::streamoff n = f.tellg();
    if (n < 0) return false;
    f.seekg(0);
    out.resize(std::size_t(n));
    if (n > 0) f.read(reinterpret_cast<char*>(out.data()), n);
    return bool(f);
}

bool writeBinaryFile(const std::string& path, const std::vector<uint8_t>& data) {
    std::error_code ec;
    auto p = fsPath(path);
    if (p.has_parent_path()) std::filesystem::create_directories(p.parent_path(), ec);
    auto tmp = p; tmp += ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
        if (!f) return false;
    }
    std::filesystem::rename(tmp, p, ec);
    return !ec;
}

std::string cacheDirectory() {
#if defined(_WIN32)
    if (const char* l = std::getenv("LOCALAPPDATA")) return std::string(l) + "\\PlaneWorld\\Cache";
    return (std::filesystem::temp_directory_path() / "PlaneWorld").string();
#elif defined(__APPLE__)
    if (const char* h = std::getenv("HOME")) return std::string(h) + "/Library/Caches/PlaneWorld";
    return "/tmp/PlaneWorld";
#else
    if (const char* x = std::getenv("XDG_CACHE_HOME")) return std::string(x) + "/PlaneWorld";
    if (const char* h = std::getenv("HOME")) return std::string(h) + "/.cache/PlaneWorld";
    return "/tmp/PlaneWorld";
#endif
}

#if !defined(__APPLE__) && !defined(_WIN32)
bool httpGet(const std::string&, double, std::vector<uint8_t>&, int& status, std::string& err) {
    status = 0; err = "HTTP not implemented on this platform"; return false;
}
#endif

} // namespace pw::env
