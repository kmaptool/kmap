#ifndef KMAP_RADIX_SORT_H
#define KMAP_RADIX_SORT_H

#include <stddef.h>
#include <stdint.h>

// Sorts `count` signed 64-bit ids ascending, in `ids`, with `scratch` of the same length
// to work in. A byte at a time from the lowest, skipping every byte the ids all share:
// OSM ids fill 5 bytes at most, so 5 passes over the data and no comparison.
void kmap_sort_i64(int64_t *ids, int64_t *scratch, size_t count);

#endif
