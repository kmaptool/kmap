#ifndef KMAP_SORTED_SEARCH_H
#define KMAP_SORTED_SEARCH_H

#include <stddef.h>
#include <stdint.h>

// Looks up `count` ids in `keys`: sorted, each once, with `fences` every `stride`-th
// key. `out[i]` is where `ids[i]` sits, or -1. The searches go 16 at a time in step, so
// their misses in memory overlap rather than queue: the table is far larger than the
// cache, and a search is a chain of loads that each wait on the last.
void kmap_find_fenced(const int64_t *keys, size_t count_keys, const int64_t *fences, size_t count_fences,
                      size_t stride, const int64_t *ids, size_t count, int64_t *out);

#endif
