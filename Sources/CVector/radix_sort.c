#include "radix_sort.h"

#include <string.h>

// The digit of `value` at `byte`. The callers flip the sign bit first, so negatives
// sort first.
static inline unsigned digit(uint64_t value, unsigned byte) {
    return (unsigned)(value >> (byte * 8)) & 0xff;
}

int kmap_sort_i64_either(int64_t *ids, int64_t *scratch, size_t count) {
    if (count < 2) return 0;
    static const uint64_t sign = 0x8000000000000000ull;
    // A byte equal in the AND and the OR of all ids is the same in each: it orders nothing and is skipped.
    uint64_t all = ~0ull, any = 0;
    for (size_t i = 0; i < count; i++) {
        all &= (uint64_t)ids[i];
        any |= (uint64_t)ids[i];
    }
    unsigned bytes[8], passes = 0;
    for (unsigned byte = 0; byte < 8; byte++) {
        if (digit(all ^ any, byte)) bytes[passes++] = byte;
    }
    // Every histogram in 1 pass, odd and even ids apart: a byte that seldom changes would
    // otherwise chain additions on 1 counter.
    size_t counts[2][8][256];
    memset(counts, 0, sizeof counts);
    size_t i = 0;
    for (; i + 2 <= count; i += 2) {
        uint64_t a = (uint64_t)ids[i] ^ sign, b = (uint64_t)ids[i + 1] ^ sign;
        for (unsigned k = 0; k < passes; k++) {
            counts[0][k][digit(a, bytes[k])]++;
            counts[1][k][digit(b, bytes[k])]++;
        }
    }
    if (i < count) {
        uint64_t a = (uint64_t)ids[i] ^ sign;
        for (unsigned k = 0; k < passes; k++) counts[0][k][digit(a, bytes[k])]++;
    }
    uint64_t *from = (uint64_t *)ids, *into = (uint64_t *)scratch;
    for (unsigned k = 0; k < passes; k++) {
        size_t *bucket = counts[0][k];
        size_t at = 0;
        for (unsigned value = 0; value < 256; value++) {
            size_t held = bucket[value] + counts[1][k][value];
            bucket[value] = at;
            at += held;
        }
        unsigned byte = bytes[k];
        for (size_t j = 0; j < count; j++) {
            uint64_t value = from[j];
            into[bucket[digit(value ^ sign, byte)]++] = value;
        }
        uint64_t *swap = from;
        from = into;
        into = swap;
    }
    return from != (uint64_t *)ids;
}
