#pragma once

#include <stdint.h>

// Lock-free 32-bit load/store shared between the main thread and the real-time audio thread.

static inline uint32_t vc_atomic_load_u32(const uint32_t *pointer) {
    return __atomic_load_n(pointer, __ATOMIC_RELAXED);
}

static inline void vc_atomic_store_u32(uint32_t *pointer, uint32_t value) {
    __atomic_store_n(pointer, value, __ATOMIC_RELAXED);
}
