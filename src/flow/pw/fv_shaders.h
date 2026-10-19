#pragma once
// Embedded finite-volume Navier–Stokes shader library (cmake/PWSlangLib.cmake, shaders/flow/fv_ns.slang). Keys:
// "fv_ns.metal" (MSL source, Apple) or "fv_ns.<entry>" (DXIL, Windows). Data is NUL-terminated.
#include <cstddef>
#include "pw/shaders.h"
namespace pw::fv_shaders {
const pw::shaders::Blob* find(const char* key);
const pw::shaders::Blob* all(std::size_t& count);
}
