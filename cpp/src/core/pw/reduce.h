#pragma once
// Deterministic reductions with runtime SIMD dispatch. Every ISA path uses the SAME fixed order:
// 8 lane accumulators (lane j sums elements i = j mod 8, in index order), combined as
// ((l0+l4)+(l2+l6)) + ((l1+l5)+(l3+l7)), then the tail added in index order. Results are bit-identical across
// Scalar / NEON / AVX2 / AVX-512 (tested), so training is reproducible on any machine.
#include <cstddef>
#include "pw/cpu.h"
namespace pw {
double sum(const double* a, std::size_t n);                     // dispatched to cpu::bestLevel()
double sumWith(cpu::Level level, const double* a, std::size_t n); // explicit path (tests / bench)
double dotWith(cpu::Level level, const double* a, const double* b, std::size_t n);
double dot(const double* a, const double* b, std::size_t n);
}
