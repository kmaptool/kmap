#ifndef KMAP_ATOMIC_SLOT_H
#define KMAP_ATOMIC_SLOT_H

#include <stdint.h>

// Puts `value` into `*slot` if the slot holds 0, in 1 step no other thread can come
// between. Returns what the slot held: 0 when `value` went in. Defined here so that a
// caller in Swift has it inline, once per node.
static inline uint64_t kmap_claim_slot(uint64_t *slot, uint64_t value) {
    // Relaxed: the word is all there is to it, and the reader waits for every writer to
    // finish before it looks.
    uint64_t held = 0;
    if (__atomic_compare_exchange_n(slot, &held, value, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return 0;
    return held;
}

#endif
