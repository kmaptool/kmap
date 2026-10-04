#ifndef KMAP_RADIX_SORT_H
#define KMAP_RADIX_SORT_H

#include <stddef.h>
#include <stdint.h>

// Sorts `count` signed 64-bit ids ascending, with `scratch` of the same length to work
// in. A byte at a time from the lowest, skipping every byte the ids all share, with no
// comparison: an OSM id fills 5 bytes, so 5 passes; an id kmap invents fills 6, and
// negative ids mixed with positive ones take all 8.
//
// Each pass moves the ids from 1 array to the other, so the sorted ids end in either.
// Returns 1 when they are in `scratch`, 0 when in `ids`.
int kmap_sort_i64_either(int64_t *ids, int64_t *scratch, size_t count);

#endif
