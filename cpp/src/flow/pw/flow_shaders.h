#pragma once
// Embedded flow shader library (cmake/PWSlangLib.cmake, shaders/flow/lbm19.slang / lbm27.slang). Keys:
// "<module>.metal" (MSL source, Apple) or "<module>.<entry>" (DXIL, Windows). Data is NUL-terminated.
#include <cstddef>
#include "pw/shaders.h"
namespace pw::flow_shaders {
const pw::shaders::Blob* find(const char* key);
const pw::shaders::Blob* all(std::size_t& count);
}
