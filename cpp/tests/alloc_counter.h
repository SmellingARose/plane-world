#pragma once
// Counts global operator new calls (the "zero allocations per step" rule is enforced with this in tests).
#include <cstddef>
namespace pwtest { std::size_t allocations(); }
