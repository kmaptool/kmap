#include "packed_varint.h"

#include <string.h>

#include "vector_support.h"

// After Lemire's Masked VByte. The continuation bits of 64 bytes are gathered into
// 1 word; 12 of them pick a shuffle that puts each of the next varints in a lane of
// its own, and the 7-bit groups of every lane are closed up together.
//
//   16 bytes with no continuation bit      16 values of 1 byte
//   the next value takes up to 4 bytes     up to 4 values, 32-bit lanes
//   the next value takes 5 to 8 bytes      up to 2 values, 64-bit lanes
//   it takes 9 or 10                       1 value, a byte at a time
//
// The loops are in packed_varint_loops.h, compiled once for each set of instructions.

#if defined(KMAP_NEON) || defined(KMAP_SSE)

enum { QUADS = 0, PAIRS = 1, ALONE = 2 };

enum { WINDOW = 12, PATTERNS = 1 << WINDOW, VECTOR = 16, CHUNK = 64, LONGEST = 10 };

// For each pattern of 12 continuation bits: where the bytes go, which lanes they are
// in, how many values that makes and how many bytes it takes. 32 bytes, so a step
// is read from 1 line of the cache.
typedef struct {
    uint8_t shuffle[VECTOR];
    uint8_t kind, values, taken;
    uint8_t unused[13];
} Step;
static Step steps[PATTERNS] __attribute__((aligned(64)));

static void fill(int pattern) {
    int lengths[WINDOW];
    int found = 0, at = 0;
    while (at < WINDOW) {
        int length = 1;
        while (at + length <= WINDOW && (pattern >> (at + length - 1) & 1)) length++;
        if (at + length > WINDOW) break;
        lengths[found++] = length;
        at += length;
    }
    int lane = 0, most = 0, widest = 0;
    uint8_t kind = ALONE;
    if (found > 0 && lengths[0] <= 4) { kind = QUADS; lane = 4; most = 4; widest = 4; }
    else if (found > 0 && lengths[0] <= 8) { kind = PAIRS; lane = 8; most = 2; widest = 8; }
    // 0xFF as an index gives a zero byte on both machines.
    memset(steps[pattern].shuffle, 0xFF, VECTOR);
    int from = 0, count = 0;
    while (count < most && count < found && lengths[count] <= widest) {
        for (int j = 0; j < lengths[count]; j++) steps[pattern].shuffle[count * lane + j] = (uint8_t)(from + j);
        from += lengths[count];
        count++;
    }
    steps[pattern].kind = kind;
    steps[pattern].values = (uint8_t)count;
    steps[pattern].taken = (uint8_t)from;
}

void kmap_varints_prepare(void) {
    for (int pattern = 0; pattern < PATTERNS; pattern++) fill(pattern);
}

// 1 varint at `p`, which has 10 readable bytes. Answers its length, or 0 where it
// does not end within them.
static inline size_t alone(const uint8_t *p, uint64_t *value) {
    uint64_t result = 0;
    for (size_t i = 0; i < LONGEST; i++) {
        uint64_t byte = p[i];
        result |= (byte & 0x7F) << (7 * i);
        if (byte < 0x80) {
            *value = result;
            return i + 1;
        }
    }
    return 0;
}

// Whether any quarter of a chunk is 16 values of 1 byte.
static inline int singles(uint64_t bits) {
    const uint64_t quarter = 0xFFFF;
    return (bits & quarter) == 0 || (bits >> 16 & quarter) == 0 || (bits >> 32 & quarter) == 0 || bits >> 48 == 0;
}

#define KMAP_PASTE(a, b) a##b
#define KMAP_NAMED(a, b) KMAP_PASTE(a, b)
#define NAME(name) KMAP_NAMED(name, SUFFIX)

#if defined(KMAP_NEON)

typedef uint8x16_t bytes16;

#define SUFFIX _neon
#define TARGET
#define WITH_SHUFFLE 1
#include "packed_varint_loops.h"
#undef SUFFIX
#undef TARGET
#undef WITH_SHUFFLE

#else

typedef __m128i bytes16;

#define SUFFIX _avx2
#define TARGET KMAP_AVX2
#define WITH_SHUFFLE 1
#define WITH_WIDENING 1
#define WITH_AVX2 1
#include "packed_varint_loops.h"
#undef SUFFIX
#undef TARGET
#undef WITH_AVX2

#define SUFFIX _sse41
#define TARGET KMAP_SSE41
#include "packed_varint_loops.h"
#undef SUFFIX
#undef TARGET
#undef WITH_WIDENING

#define SUFFIX _ssse3
#define TARGET KMAP_SSSE3
#include "packed_varint_loops.h"
#undef SUFFIX
#undef TARGET
#undef WITH_SHUFFLE

#define SUFFIX _sse2
#define TARGET
#include "packed_varint_loops.h"
#undef SUFFIX
#undef TARGET

#endif

size_t kmap_varints_zigzag64(const uint8_t *in, size_t count, int64_t *out, size_t *used) {
    switch (kmap_vector_tier()) {
#if defined(KMAP_NEON)
    case KMAP_TIER_BASE: return zigzag64_neon(in, count, out, used);
#else
    case KMAP_TIER_AVX2: return zigzag64_avx2(in, count, out, used);
    case KMAP_TIER_SSE41: return zigzag64_sse41(in, count, out, used);
    case KMAP_TIER_SSSE3: return zigzag64_ssse3(in, count, out, used);
    case KMAP_TIER_BASE: return zigzag64_sse2(in, count, out, used);
#endif
    default:
        *used = 0;
        return 0;
    }
}

size_t kmap_varints_low32(const uint8_t *in, size_t count, int32_t *out, size_t *used) {
    switch (kmap_vector_tier()) {
#if defined(KMAP_NEON)
    case KMAP_TIER_BASE: return low32_neon(in, count, out, used);
#else
    case KMAP_TIER_AVX2: return low32_avx2(in, count, out, used);
    case KMAP_TIER_SSE41: return low32_sse41(in, count, out, used);
    case KMAP_TIER_SSSE3: return low32_ssse3(in, count, out, used);
    case KMAP_TIER_BASE: return low32_sse2(in, count, out, used);
#endif
    default:
        *used = 0;
        return 0;
    }
}

#else  // no vector instructions known for this machine

void kmap_varints_prepare(void) {}

size_t kmap_varints_zigzag64(const uint8_t *in, size_t count, int64_t *out, size_t *used) {
    (void)in; (void)count; (void)out;
    *used = 0;
    return 0;
}

size_t kmap_varints_low32(const uint8_t *in, size_t count, int32_t *out, size_t *used) {
    (void)in; (void)count; (void)out;
    *used = 0;
    return 0;
}

#endif
