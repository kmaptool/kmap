#include "radix_sort.h"

#include <string.h>

// The digit of `value` at `byte`; the top byte is flipped so that negatives sort first.
static inline unsigned digit(uint64_t value, unsigned byte) {
    return (unsigned)(value >> (byte * 8)) & 0xff;
}

void kmap_sort_i64(int64_t *ids, int64_t *scratch, size_t count) {
    if (count < 2) return;
    // Every byte's histogram in 1 pass over the data.
    static const uint64_t sign = 0x8000000000000000ull;
    size_t counts[8][256];
    memset(counts, 0, sizeof counts);
    for (size_t i = 0; i < count; i++) {
        uint64_t value = (uint64_t)ids[i] ^ sign;
        for (unsigned byte = 0; byte < 8; byte++) counts[byte][digit(value, byte)]++;
    }
    uint64_t *from = (uint64_t *)ids, *into = (uint64_t *)scratch;
    for (unsigned byte = 0; byte < 8; byte++) {
        size_t *bucket = counts[byte];
        // A byte every id shares orders nothing.
        if (bucket[digit((uint64_t)from[0] ^ sign, byte)] == count) continue;
        size_t at = 0;
        for (unsigned value = 0; value < 256; value++) {
            size_t held = bucket[value];
            bucket[value] = at;
            at += held;
        }
        for (size_t i = 0; i < count; i++) {
            uint64_t value = from[i];
            into[bucket[digit(value ^ sign, byte)]++] = value;
        }
        uint64_t *swap = from;
        from = into;
        into = swap;
    }
    if (from != (uint64_t *)ids) memcpy(ids, from, count * sizeof *ids);
}
