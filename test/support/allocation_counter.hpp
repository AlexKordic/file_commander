#pragma once
#include <atomic>
#include <cstdlib>
#include <new>
// Benchmark executable only: count C++ allocation calls, including aligned new.
// This deliberately does not claim to count direct malloc calls in libraries.
inline std::atomic<size_t> test_allocations{0};
inline void*               test_allocate(size_t bytes, size_t alignment = 0) {
  ++test_allocations;
  void* result = nullptr;
  if (alignment) {
    if (posix_memalign(&result, alignment, bytes ? bytes : 1) != 0) result = nullptr;
  } else result = std::malloc(bytes ? bytes : 1);
  if (!result) throw std::bad_alloc();
  return result;
}
void* operator new(size_t n) { return test_allocate(n); }
void* operator new[](size_t n) { return test_allocate(n); }
void  operator delete(void* p) noexcept { std::free(p); }
void  operator delete[](void* p) noexcept { std::free(p); }
void  operator delete(void* p, size_t) noexcept { std::free(p); }
void  operator delete[](void* p, size_t) noexcept { std::free(p); }
void* operator new(size_t n, std::align_val_t a) { return test_allocate(n, static_cast<size_t>(a)); }
void* operator new[](size_t n, std::align_val_t a) { return test_allocate(n, static_cast<size_t>(a)); }
void  operator delete(void* p, std::align_val_t) noexcept { std::free(p); }
void  operator delete[](void* p, std::align_val_t) noexcept { std::free(p); }
void  operator delete(void* p, size_t, std::align_val_t) noexcept { std::free(p); }
void  operator delete[](void* p, size_t, std::align_val_t) noexcept { std::free(p); }
