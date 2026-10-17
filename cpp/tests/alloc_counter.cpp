#include "alloc_counter.h"
#include <atomic>
#include <cstdlib>
#include <new>
namespace { std::atomic<std::size_t> g_allocs{0}; }
namespace pwtest { std::size_t allocations() { return g_allocs.load(); } }
void* operator new(std::size_t n) { g_allocs.fetch_add(1, std::memory_order_relaxed); if (void* p = std::malloc(n ? n : 1)) return p; throw std::bad_alloc(); }
void* operator new[](std::size_t n) { g_allocs.fetch_add(1, std::memory_order_relaxed); if (void* p = std::malloc(n ? n : 1)) return p; throw std::bad_alloc(); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
