#include "float_predictor.h"

#include <string.h>

#include "vector_support.h"

#if defined(KMAP_NEON) || defined(KMAP_SSE)

enum { VECTOR = 16 };

// The running sum of the bytes of 1 row, 16 at a time: within a vector by adding it
// to itself moved along by 1, 2, 4 and 8 bytes, and across vectors by its last byte.
KMAP_TARGET
static inline void sums(uint8_t *row, size_t count) {
    size_t i = 0;
    uint8_t last = 0;
#if defined(KMAP_NEON)
    const uint8x16_t zero = vdupq_n_u8(0);
    uint8x16_t carry = zero;
    for (; i + VECTOR <= count; i += VECTOR) {
        uint8x16_t x = vld1q_u8(row + i);
        x = vaddq_u8(x, vextq_u8(zero, x, 15));
        x = vaddq_u8(x, vextq_u8(zero, x, 14));
        x = vaddq_u8(x, vextq_u8(zero, x, 12));
        x = vaddq_u8(x, vextq_u8(zero, x, 8));
        x = vaddq_u8(x, carry);
        carry = vdupq_laneq_u8(x, 15);
        vst1q_u8(row + i, x);
    }
    last = vgetq_lane_u8(carry, 0);
#else
    const __m128i end = _mm_set1_epi8(15);
    __m128i carry = _mm_setzero_si128();
    for (; i + VECTOR <= count; i += VECTOR) {
        __m128i x = _mm_loadu_si128((const __m128i *)(row + i));
        x = _mm_add_epi8(x, _mm_slli_si128(x, 1));
        x = _mm_add_epi8(x, _mm_slli_si128(x, 2));
        x = _mm_add_epi8(x, _mm_slli_si128(x, 4));
        x = _mm_add_epi8(x, _mm_slli_si128(x, 8));
        x = _mm_add_epi8(x, carry);
        carry = _mm_shuffle_epi8(x, end);
        _mm_storeu_si128((__m128i *)(row + i), x);
    }
    last = (uint8_t)_mm_cvtsi128_si32(carry);
#endif
    for (; i < count; i++) {
        last = (uint8_t)(last + row[i]);
        row[i] = last;
    }
}

// 1 byte from each plane makes a sample, the first plane its most significant byte.
KMAP_TARGET
static inline void gather(const uint8_t *row, size_t width, float *out) {
    const uint8_t *p0 = row, *p1 = row + width, *p2 = row + 2 * width, *p3 = row + 3 * width;
    size_t s = 0;
#if defined(KMAP_NEON)
    for (; s + VECTOR <= width; s += VECTOR) {
        uint8x16x4_t planes = {{vld1q_u8(p3 + s), vld1q_u8(p2 + s), vld1q_u8(p1 + s), vld1q_u8(p0 + s)}};
        vst4q_u8((uint8_t *)(out + s), planes);
    }
#else
    for (; s + VECTOR <= width; s += VECTOR) {
        __m128i b3 = _mm_loadu_si128((const __m128i *)(p3 + s)), b2 = _mm_loadu_si128((const __m128i *)(p2 + s));
        __m128i b1 = _mm_loadu_si128((const __m128i *)(p1 + s)), b0 = _mm_loadu_si128((const __m128i *)(p0 + s));
        __m128i low32 = _mm_unpacklo_epi8(b3, b2), high32 = _mm_unpackhi_epi8(b3, b2);
        __m128i low10 = _mm_unpacklo_epi8(b1, b0), high10 = _mm_unpackhi_epi8(b1, b0);
        __m128i *to = (__m128i *)(out + s);
        _mm_storeu_si128(to, _mm_unpacklo_epi16(low32, low10));
        _mm_storeu_si128(to + 1, _mm_unpackhi_epi16(low32, low10));
        _mm_storeu_si128(to + 2, _mm_unpacklo_epi16(high32, high10));
        _mm_storeu_si128(to + 3, _mm_unpackhi_epi16(high32, high10));
    }
#endif
    for (; s < width; s++) {
        uint32_t bits = (uint32_t)p0[s] << 24 | (uint32_t)p1[s] << 16 | (uint32_t)p2[s] << 8 | (uint32_t)p3[s];
        memcpy(out + s, &bits, sizeof bits);
    }
}

KMAP_TARGET
int kmap_float_rows(uint8_t *raw, size_t width, size_t rows, float *out) {
#if defined(KMAP_SSE)
    if (!kmap_has_sse41()) return 0;
#endif
    for (size_t r = 0; r < rows; r++) {
        uint8_t *row = raw + r * width * 4;
        sums(row, width * 4);
        gather(row, width, out + r * width);
    }
    return 1;
}

#else

int kmap_float_rows(uint8_t *raw, size_t width, size_t rows, float *out) {
    (void)raw; (void)width; (void)rows; (void)out;
    return 0;
}

#endif
