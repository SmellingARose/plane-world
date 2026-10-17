#pragma once
// Craft JSON embedded at build time (cmake/PWEmbedCrafts.cmake). Arrays end with a {nullptr} entry.
#include <cstddef>
namespace pw::craft::embedded {
struct Blob { const char* name; const char* file; const char* data; std::size_t size; };
const Blob* presets();
const Blob* examples();
}
