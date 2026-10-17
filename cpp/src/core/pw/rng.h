#pragma once
#include <cstdint>
namespace pw {
/// SplitMix64, identical to the Swift `SplitMix` (NaNHunt / evolution seeding): next() in [0, 1) with 53 bits.
struct SplitMix {
    uint64_t s;
    explicit SplitMix(uint64_t seed) : s(seed) {}
    uint64_t nextU64() {
        s += 0x9E3779B97F4A7C15ull;
        uint64_t z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    double next() { return double(nextU64() >> 11) / double(1ull << 53); }
};
}
