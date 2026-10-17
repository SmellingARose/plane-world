#pragma once
#include <cstddef>
// Embedded compiled shaders (cmake/PWSlang.cmake). Keys: "<name>.metal" on Apple, "<name>.vs" / "<name>.ps"
// (DXIL) on Windows. The data is NUL-terminated (size excludes the NUL), so MSL can be used as a C string.
namespace pw::shaders {
struct Blob { const char* key; const unsigned char* data; std::size_t size; };
const Blob* find(const char* key);
}
