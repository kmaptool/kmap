#include "sorted_search.h"

enum { LANES = 16 };

// Each step halves every search that is still open, with no branch on what it read,
// and asks for the 2 places the next step can look at before it waits on this one.
static void group(const int64_t *keys, size_t count_keys, const int64_t *fences, size_t count_fences,
                  size_t stride, const int64_t *ids, size_t lanes, int64_t *out) {
    const int64_t *base[LANES];
    size_t length = count_fences;
    for (size_t j = 0; j < lanes; j++) base[j] = fences;
    // How many fences are not past the id: the window it can be in is the last of those.
    while (length > 1) {
        size_t half = length / 2;
        for (size_t j = 0; j < lanes; j++) {
            __builtin_prefetch(base[j] + half / 2);
            __builtin_prefetch(base[j] + half + half / 2);
        }
        for (size_t j = 0; j < lanes; j++) base[j] = base[j][half] <= ids[j] ? base[j] + half : base[j];
        length -= half;
    }
    size_t left[LANES];
    for (size_t j = 0; j < lanes; j++) {
        size_t below = (size_t)(base[j] - fences) + (base[j][0] <= ids[j]);
        if (below == 0) {
            left[j] = 0;
            base[j] = 0;
            continue;
        }
        size_t start = (below - 1) * stride;
        size_t end = start + stride < count_keys ? start + stride : count_keys;
        base[j] = keys + start;
        left[j] = end - start;
    }
    // The first key not below the id, inside that window.
    for (int open = 1; open;) {
        open = 0;
        for (size_t j = 0; j < lanes; j++) {
            if (left[j] <= 1) continue;
            size_t half = left[j] / 2;
            __builtin_prefetch(base[j] + half / 2);
            __builtin_prefetch(base[j] + half + half / 2);
        }
        for (size_t j = 0; j < lanes; j++) {
            if (left[j] <= 1) continue;
            size_t half = left[j] / 2;
            base[j] = base[j][half] < ids[j] ? base[j] + half : base[j];
            left[j] -= half;
            open = 1;
        }
    }
    for (size_t j = 0; j < lanes; j++) {
        if (!base[j]) {
            out[j] = -1;
            continue;
        }
        size_t at = (size_t)(base[j] - keys);
        size_t window = (at / stride) * stride;
        size_t end = window + stride < count_keys ? window + stride : count_keys;
        if (base[j][0] < ids[j]) at++;
        out[j] = at < end && keys[at] == ids[j] ? (int64_t)at : -1;
    }
}

void kmap_find_fenced(const int64_t *keys, size_t count_keys, const int64_t *fences, size_t count_fences,
                      size_t stride, const int64_t *ids, size_t count, int64_t *out) {
    if (count_fences == 0 || count_keys == 0) {
        for (size_t i = 0; i < count; i++) out[i] = -1;
        return;
    }
    // An id 1 above the id before it sits right after it in the table or nowhere: the
    // keys are sorted and each is there once. A way's nodes are often numbered in a row,
    // so only the first id of each such row is searched for.
    int64_t heads[LANES], found[LANES];
    size_t where[LANES], held = 0;
    for (size_t i = 0; i < count; i++) {
        if (i > 0 && (uint64_t)ids[i] == (uint64_t)ids[i - 1] + 1) continue;
        heads[held] = ids[i];
        where[held] = i;
        if (++held == LANES) {
            group(keys, count_keys, fences, count_fences, stride, heads, LANES, found);
            for (size_t j = 0; j < LANES; j++) out[where[j]] = found[j];
            held = 0;
        }
    }
    if (held) {
        group(keys, count_keys, fences, count_fences, stride, heads, held, found);
        for (size_t j = 0; j < held; j++) out[where[j]] = found[j];
    }
    for (size_t i = 1; i < count; i++) {
        if ((uint64_t)ids[i] != (uint64_t)ids[i - 1] + 1) continue;
        int64_t before = out[i - 1];
        if (before >= 0) {
            size_t at = (size_t)before + 1;
            out[i] = at < count_keys && keys[at] == ids[i] ? (int64_t)at : -1;
        } else {
            // The id before it is not in the table, which says nothing about this one.
            group(keys, count_keys, fences, count_fences, stride, ids + i, 1, out + i);
        }
    }
}
