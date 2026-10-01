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

static int vectored = 0;

void kmap_varints_prepare(void) {
    for (int pattern = 0; pattern < PATTERNS; pattern++) fill(pattern);
#if defined(KMAP_NEON)
    vectored = 1;
#else
    vectored = kmap_has_sse41();
#endif
}

int kmap_varints_vectored(void) { return vectored; }

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

#if defined(KMAP_NEON)

typedef uint8x16_t bytes16;
typedef int64x2_t wide2;
typedef int32x4_t wide4;

static inline bytes16 load(const uint8_t *p) { return vld1q_u8(p); }

// The continuation bits of 64 bytes, 1 bit a byte.
static inline uint64_t continuations(const uint8_t *p) {
    const uint8x16_t weights = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
    uint8x16_t a = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p))), weights);
    uint8x16_t b = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 16))), weights);
    uint8x16_t c = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 32))), weights);
    uint8x16_t d = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 48))), weights);
    uint8x16_t sum = vpaddq_u8(vpaddq_u8(a, b), vpaddq_u8(c, d));
    return vgetq_lane_u64(vreinterpretq_u64_u8(vpaddq_u8(sum, sum)), 0);
}

static inline bytes16 shuffled(bytes16 bytes, const uint8_t *shuffle) { return vqtbl1q_u8(bytes, vld1q_u8(shuffle)); }

// 4 lanes of up to 4 bytes each, as their values.
static inline uint32x4_t quads(bytes16 lanes) {
    uint32x4_t l = vreinterpretq_u32_u8(lanes);
    uint32x4_t v = vandq_u32(l, vdupq_n_u32(0x7F));
    v = vorrq_u32(v, vandq_u32(vshrq_n_u32(l, 1), vdupq_n_u32(0x7F << 7)));
    v = vorrq_u32(v, vandq_u32(vshrq_n_u32(l, 2), vdupq_n_u32(0x7F << 14)));
    return vorrq_u32(v, vandq_u32(vshrq_n_u32(l, 3), vdupq_n_u32(0x7F << 21)));
}

// 2 lanes of up to 8 bytes each, as their values.
static inline uint64x2_t pairs(bytes16 lanes) {
    uint64x2_t l = vreinterpretq_u64_u8(lanes);
    uint64x2_t v = vandq_u64(l, vdupq_n_u64(0x7F));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 1), vdupq_n_u64(0x7FULL << 7)));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 2), vdupq_n_u64(0x7FULL << 14)));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 3), vdupq_n_u64(0x7FULL << 21)));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 4), vdupq_n_u64(0x7FULL << 28)));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 5), vdupq_n_u64(0x7FULL << 35)));
    v = vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 6), vdupq_n_u64(0x7FULL << 42)));
    return vorrq_u64(v, vandq_u64(vshrq_n_u64(l, 7), vdupq_n_u64(0x7FULL << 49)));
}

static inline void zigzagBytes(bytes16 bytes, int64_t *o) {
    int8x16_t z = veorq_s8(
        vreinterpretq_s8_u8(vshrq_n_u8(bytes, 1)),
        vnegq_s8(vreinterpretq_s8_u8(vandq_u8(bytes, vdupq_n_u8(1)))));
    int16x8_t a = vmovl_s8(vget_low_s8(z)), b = vmovl_s8(vget_high_s8(z));
    int32x4_t a0 = vmovl_s16(vget_low_s16(a)), a1 = vmovl_s16(vget_high_s16(a));
    int32x4_t b0 = vmovl_s16(vget_low_s16(b)), b1 = vmovl_s16(vget_high_s16(b));
    vst1q_s64(o, vmovl_s32(vget_low_s32(a0)));
    vst1q_s64(o + 2, vmovl_s32(vget_high_s32(a0)));
    vst1q_s64(o + 4, vmovl_s32(vget_low_s32(a1)));
    vst1q_s64(o + 6, vmovl_s32(vget_high_s32(a1)));
    vst1q_s64(o + 8, vmovl_s32(vget_low_s32(b0)));
    vst1q_s64(o + 10, vmovl_s32(vget_high_s32(b0)));
    vst1q_s64(o + 12, vmovl_s32(vget_low_s32(b1)));
    vst1q_s64(o + 14, vmovl_s32(vget_high_s32(b1)));
}

static inline void zigzagQuads(bytes16 lanes, int64_t *o) {
    uint32x4_t v = quads(lanes);
    int32x4_t z = veorq_s32(
        vreinterpretq_s32_u32(vshrq_n_u32(v, 1)),
        vnegq_s32(vreinterpretq_s32_u32(vandq_u32(v, vdupq_n_u32(1)))));
    vst1q_s64(o, vmovl_s32(vget_low_s32(z)));
    vst1q_s64(o + 2, vmovl_s32(vget_high_s32(z)));
}

static inline void zigzagPairs(bytes16 lanes, int64_t *o) {
    uint64x2_t v = pairs(lanes);
    vst1q_s64(o, veorq_s64(
        vreinterpretq_s64_u64(vshrq_n_u64(v, 1)),
        vnegq_s64(vreinterpretq_s64_u64(vandq_u64(v, vdupq_n_u64(1))))));
}

static inline void lowBytes(bytes16 bytes, int32_t *o) {
    uint16x8_t a = vmovl_u8(vget_low_u8(bytes)), b = vmovl_u8(vget_high_u8(bytes));
    vst1q_s32(o, vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(a))));
    vst1q_s32(o + 4, vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(a))));
    vst1q_s32(o + 8, vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(b))));
    vst1q_s32(o + 12, vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(b))));
}

static inline void lowQuads(bytes16 lanes, int32_t *o) { vst1q_s32(o, vreinterpretq_s32_u32(quads(lanes))); }

static inline void lowPairs(bytes16 lanes, int32_t *o) {
    vst1_s32(o, vreinterpret_s32_u32(vmovn_u64(pairs(lanes))));
}

#else  // KMAP_SSE

typedef __m128i bytes16;

KMAP_TARGET
static inline bytes16 load(const uint8_t *p) { return _mm_loadu_si128((const __m128i *)p); }

// The continuation bits of 64 bytes, 1 bit a byte.
KMAP_TARGET
static inline uint64_t continuations(const uint8_t *p) {
    uint64_t a = (uint32_t)_mm_movemask_epi8(load(p)), b = (uint32_t)_mm_movemask_epi8(load(p + 16));
    uint64_t c = (uint32_t)_mm_movemask_epi8(load(p + 32)), d = (uint32_t)_mm_movemask_epi8(load(p + 48));
    return a | b << 16 | c << 32 | d << 48;
}

KMAP_TARGET
static inline bytes16 shuffled(bytes16 bytes, const uint8_t *shuffle) { return _mm_shuffle_epi8(bytes, load(shuffle)); }

// 4 lanes of up to 4 bytes each, as their values.
KMAP_TARGET
static inline __m128i quads(bytes16 l) {
    __m128i v = _mm_and_si128(l, _mm_set1_epi32(0x7F));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi32(l, 1), _mm_set1_epi32(0x7F << 7)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi32(l, 2), _mm_set1_epi32(0x7F << 14)));
    return _mm_or_si128(v, _mm_and_si128(_mm_srli_epi32(l, 3), _mm_set1_epi32(0x7F << 21)));
}

// 2 lanes of up to 8 bytes each, as their values.
KMAP_TARGET
static inline __m128i pairs(bytes16 l) {
    __m128i v = _mm_and_si128(l, _mm_set1_epi64x(0x7F));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 1), _mm_set1_epi64x(0x7FLL << 7)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 2), _mm_set1_epi64x(0x7FLL << 14)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 3), _mm_set1_epi64x(0x7FLL << 21)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 4), _mm_set1_epi64x(0x7FLL << 28)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 5), _mm_set1_epi64x(0x7FLL << 35)));
    v = _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 6), _mm_set1_epi64x(0x7FLL << 42)));
    return _mm_or_si128(v, _mm_and_si128(_mm_srli_epi64(l, 7), _mm_set1_epi64x(0x7FLL << 49)));
}

KMAP_TARGET
static inline void zigzagBytes(bytes16 bytes, int64_t *o) {
    // There is no shift of bytes: pairs are shifted, and the bit that crosses into
    // the lower byte is masked off.
    __m128i z = _mm_xor_si128(
        _mm_and_si128(_mm_srli_epi16(bytes, 1), _mm_set1_epi8(0x7F)),
        _mm_sub_epi8(_mm_setzero_si128(), _mm_and_si128(bytes, _mm_set1_epi8(1))));
    for (int i = 0; i < 8; i++) {
        _mm_storeu_si128((__m128i *)(o + 2 * i), _mm_cvtepi8_epi64(z));
        z = _mm_srli_si128(z, 2);
    }
}

KMAP_TARGET
static inline void zigzagQuads(bytes16 lanes, int64_t *o) {
    __m128i v = quads(lanes);
    __m128i z = _mm_xor_si128(
        _mm_srli_epi32(v, 1),
        _mm_sub_epi32(_mm_setzero_si128(), _mm_and_si128(v, _mm_set1_epi32(1))));
    _mm_storeu_si128((__m128i *)o, _mm_cvtepi32_epi64(z));
    _mm_storeu_si128((__m128i *)(o + 2), _mm_cvtepi32_epi64(_mm_srli_si128(z, 8)));
}

KMAP_TARGET
static inline void zigzagPairs(bytes16 lanes, int64_t *o) {
    __m128i v = pairs(lanes);
    _mm_storeu_si128(
        (__m128i *)o,
        _mm_xor_si128(_mm_srli_epi64(v, 1), _mm_sub_epi64(_mm_setzero_si128(), _mm_and_si128(v, _mm_set1_epi64x(1)))));
}

KMAP_TARGET
static inline void lowBytes(bytes16 bytes, int32_t *o) {
    _mm_storeu_si128((__m128i *)o, _mm_cvtepu8_epi32(bytes));
    _mm_storeu_si128((__m128i *)(o + 4), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 4)));
    _mm_storeu_si128((__m128i *)(o + 8), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 8)));
    _mm_storeu_si128((__m128i *)(o + 12), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 12)));
}

KMAP_TARGET
static inline void lowQuads(bytes16 lanes, int32_t *o) { _mm_storeu_si128((__m128i *)o, quads(lanes)); }

KMAP_TARGET
static inline void lowPairs(bytes16 lanes, int32_t *o) {
    __m128i v = pairs(lanes);
    o[0] = _mm_cvtsi128_si32(v);
    o[1] = _mm_extract_epi32(v, 2);
}

#endif

// Lanes are stored whole, 4 or 2 at a time, and only the values among them are
// counted: the next store writes over the rest.

KMAP_TARGET
size_t kmap_varints_zigzag64(const uint8_t *in, size_t count, int64_t *out, size_t *used) {
    const uint8_t *p = in, *end = in + (vectored ? count : 0);
    int64_t *o = out;
    while ((size_t)(end - p) >= CHUNK) {
        uint64_t bits = continuations(p);
        const uint8_t *q = p, *last = p + (CHUNK - VECTOR);
        while (q <= last) {
            uint32_t ahead = (uint32_t)bits & 0xFFFF;
            bytes16 bytes = load(q);
            if (ahead == 0) {
                zigzagBytes(bytes, o);
                o += VECTOR;
                q += VECTOR;
                bits >>= VECTOR;
                continue;
            }
            const Step *step = &steps[ahead & (PATTERNS - 1)];
            bytes16 lanes = shuffled(bytes, step->shuffle);
            if (step->kind == QUADS) {
                zigzagQuads(lanes, o);
            } else if (step->kind == PAIRS) {
                zigzagPairs(lanes, o);
            } else {
                uint64_t raw;
                size_t length = alone(q, &raw);
                if (length == 0) {
                    p = q;
                    goto done;
                }
                *o++ = (int64_t)(raw >> 1) ^ -(int64_t)(raw & 1);
                q += length;
                bits >>= length;
                continue;
            }
            o += step->values;
            q += step->taken;
            bits >>= step->taken;
        }
        p = q;
    }
done:
    *used = (size_t)(p - in);
    return (size_t)(o - out);
}

KMAP_TARGET
size_t kmap_varints_low32(const uint8_t *in, size_t count, int32_t *out, size_t *used) {
    const uint8_t *p = in, *end = in + (vectored ? count : 0);
    int32_t *o = out;
    while ((size_t)(end - p) >= CHUNK) {
        uint64_t bits = continuations(p);
        const uint8_t *q = p, *last = p + (CHUNK - VECTOR);
        while (q <= last) {
            uint32_t ahead = (uint32_t)bits & 0xFFFF;
            bytes16 bytes = load(q);
            if (ahead == 0) {
                lowBytes(bytes, o);
                o += VECTOR;
                q += VECTOR;
                bits >>= VECTOR;
                continue;
            }
            const Step *step = &steps[ahead & (PATTERNS - 1)];
            bytes16 lanes = shuffled(bytes, step->shuffle);
            if (step->kind == QUADS) {
                lowQuads(lanes, o);
            } else if (step->kind == PAIRS) {
                lowPairs(lanes, o);
            } else {
                uint64_t raw;
                size_t length = alone(q, &raw);
                if (length == 0) {
                    p = q;
                    goto done;
                }
                *o++ = (int32_t)(uint32_t)raw;
                q += length;
                bits >>= length;
                continue;
            }
            o += step->values;
            q += step->taken;
            bits >>= step->taken;
        }
        p = q;
    }
done:
    *used = (size_t)(p - in);
    return (size_t)(o - out);
}

#else  // no vector instructions known for this machine

void kmap_varints_prepare(void) {}
int kmap_varints_vectored(void) { return 0; }

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
