#ifndef KMAP_SORTED_SEARCH_H
#define KMAP_SORTED_SEARCH_H

#include <stddef.h>
#include <stdint.h>

// Looks up `count` ids in `keys` (sorted, unique, with `fences` every `stride`-th key);
// `out[i]` is where `ids[i]` sits, or -1. 16 searches run in step so their cache misses
// overlap rather than queue. A `stride` of 0, or no keys or fences, answers -1 for all.
void kmap_find_fenced(const int64_t *keys, size_t count_keys, const int64_t *fences, size_t count_fences,
                      size_t stride, const int64_t *ids, size_t count, int64_t *out);

#endif
