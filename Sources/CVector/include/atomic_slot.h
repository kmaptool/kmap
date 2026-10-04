#ifndef KMAP_ATOMIC_SLOT_H
#define KMAP_ATOMIC_SLOT_H

#include <stdint.h>

// Puts `value` into `*slot` if the slot holds 0, in 1 step no other thread can come
// between. Returns what the slot held: 0 when `value` went in.
uint64_t kmap_claim_slot(uint64_t *slot, uint64_t value);

#endif
