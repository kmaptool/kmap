#include "atomic_slot.h"

uint64_t kmap_claim_slot(uint64_t *slot, uint64_t value) {
    // Relaxed: the word is all there is to it, and the reader waits for every writer to
    // finish before it looks.
    uint64_t held = 0;
    if (__atomic_compare_exchange_n(slot, &held, value, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return 0;
    return held;
}
