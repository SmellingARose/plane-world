#pragma once
// Embedded env shader library (cmake/PWSlangLib.cmake, shaders/env/*.slang). Keys: "<module>.metal" (MSL source,
// Apple) or "<module>.<entry>" (DXIL, Windows). Data is NUL-terminated (size excludes the NUL).
#include <cstddef>
#include "pw/shaders.h"
namespace pw::env_shaders {
const pw::shaders::Blob* find(const char* key);
const pw::shaders::Blob* all(std::size_t& count);
}
