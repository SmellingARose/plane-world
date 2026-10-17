#pragma once
// Byte-level codecs shared by terrain / water / vegetation:
//   * IEEE half floats (round-to-nearest-even, Swift Float16(x) semantics)
//   * raw DEFLATE (RFC 1951) - the format of Foundation's NSData .zlib compression, so terrain edits written
//     by the Swift app load here and vice versa
//   * image decoding (PNG 8/16-bit, JPEG, BMP, TGA, ... via stb_image, no colour management) and a 16-bit
//     grayscale PNG writer (heightmap export / tests)
//   * a minimal blocking HTTPS GET (NSURLSession on Apple, WinHTTP on Windows) for DEM tiles
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace pw::env {

/// UTF-8 string -> filesystem path (std::filesystem::u8path is deprecated in C++20).
inline std::filesystem::path fsPath(const std::string& utf8) {
    return std::filesystem::path(std::u8string(utf8.begin(), utf8.end()));
}

uint16_t floatToHalf(float f);
float halfToFloat(uint16_t h);

/// Raw DEFLATE (no zlib header). level 0..9 (-1 = default).
bool deflateRaw(const uint8_t* data, std::size_t n, std::vector<uint8_t>& out, int level = -1);
/// Inflate raw DEFLATE. `expected` (optional) pre-sizes the output; fails on corrupt input.
bool inflateRaw(const uint8_t* data, std::size_t n, std::vector<uint8_t>& out, std::size_t expected = 0);

/// Decoded image, row-major, top row first. `channels` 1..4; samples are 8 or 16 bit (stored in `u16` when 16).
struct Image {
    int width = 0, height = 0, channels = 0, bits = 8;
    std::vector<uint8_t> u8;
    std::vector<uint16_t> u16;
    bool valid() const { return width > 0 && height > 0; }
};
/// Decode from memory. 16-bit PNGs keep 16 bits; everything else is 8-bit. No gamma / ICC conversion.
bool decodeImage(const uint8_t* data, std::size_t n, Image& out, std::string* err = nullptr);
bool loadImageFile(const std::string& path, Image& out, std::string* err = nullptr);
/// Force RGBA8 (exact bytes for 8-bit RGB(A) sources; terrarium DEM decode relies on that).
bool decodeRGBA8(const uint8_t* data, std::size_t n, int& w, int& h, std::vector<uint8_t>& rgba);

/// 16-bit grayscale PNG (values 0..1, rounded to 0..65535).
bool encodePNG16(const std::vector<float>& values, int width, int height, std::vector<uint8_t>& png);
/// 8-bit PNG, RGBA (4 channels) or gray (1 channel).
bool encodePNG8(const uint8_t* pixels, int width, int height, int channels, std::vector<uint8_t>& png);

bool readBinaryFile(const std::string& path, std::vector<uint8_t>& out);
bool writeBinaryFile(const std::string& path, const std::vector<uint8_t>& data);   // creates parent dirs, atomic rename

/// Blocking HTTP(S) GET. Returns true on transport success (check status); body in `out`.
bool httpGet(const std::string& url, double timeoutSeconds, std::vector<uint8_t>& out, int& status, std::string& err);

/// Per-user cache directory for Plane World ("~/Library/Caches/PlaneWorld" on macOS,
/// "%LOCALAPPDATA%/PlaneWorld/Cache" on Windows, "$XDG_CACHE_HOME/PlaneWorld" elsewhere).
std::string cacheDirectory();

} // namespace pw::env
