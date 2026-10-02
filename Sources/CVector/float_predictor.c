#include "float_predictor.h"

#include <string.h>

#include "vector_support.h"

#if defined(KMAP_NEON) || defined(KMAP_SSE)

enum { VECTOR = 16 };

// What a vector loop left of a row, a byte at a time.
static inline void rest(uint8_t *row, size_t i, size_t count, uint8_t last) {
    for (; i < count; i++) {
        last = (uint8_t)(last + row[i]);
        row[i] = last;
    }
}

// The running sum of the bytes of 1 row, 16 at a time: within a vector by adding it
// to itself moved along by 1, 2, 4 and 8 bytes, and across vectors by its last byte.

#if defined(KMAP_NEON)

static void sums(uint8_t *row, size_t count, int tier) {
    (void)tier;
    const uint8x16_t zero = vdupq_n_u8(0);
    uint8x16_t carry = zero;
    size_t i = 0;
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
    rest(row, i, count, vgetq_lane_u8(carry, 0));
}

#else

// The sums inside 1 vector.
static inline __m128i within(__m128i x) {
    x = _mm_add_epi8(x, _mm_slli_si128(x, 1));
    x = _mm_add_epi8(x, _mm_slli_si128(x, 2));
    x = _mm_add_epi8(x, _mm_slli_si128(x, 4));
    return _mm_add_epi8(x, _mm_slli_si128(x, 8));
}

// SSE2 has no byte shuffle, so the last byte reaches all 16 in 3 steps: doubled into
// the top word, then the word and the doubleword it is in spread over the rest.
static void sums_sse2(uint8_t *row, size_t count) {
    __m128i carry = _mm_setzero_si128();
    size_t i = 0;
    for (; i + VECTOR <= count; i += VECTOR) {
        __m128i x = _mm_add_epi8(within(_mm_loadu_si128((const __m128i *)(row + i))), carry);
        carry = _mm_shuffle_epi32(_mm_shufflehi_epi16(_mm_unpackhi_epi8(x, x), 0xFF), 0xFF);
        _mm_storeu_si128((__m128i *)(row + i), x);
    }
    rest(row, i, count, (uint8_t)_mm_cvtsi128_si32(carry));
}

KMAP_SSSE3
static void sums_ssse3(uint8_t *row, size_t count) {
    const __m128i end = _mm_set1_epi8(15);
    __m128i carry = _mm_setzero_si128();
    size_t i = 0;
    for (; i + VECTOR <= count; i += VECTOR) {
        __m128i x = _mm_add_epi8(within(_mm_loadu_si128((const __m128i *)(row + i))), carry);
        carry = _mm_shuffle_epi8(x, end);
        _mm_storeu_si128((__m128i *)(row + i), x);
    }
    rest(row, i, count, (uint8_t)_mm_cvtsi128_si32(carry));
}

// 32 bytes at a time: each half summed as `within` does, then the low half's last
// byte added to all of the high half. The block's total is found before the carry is
// added, so from one block to the next the carry waits for 1 addition only.
KMAP_AVX2
static void sums_avx2(uint8_t *row, size_t count) {
    const __m256i end = _mm256_set1_epi8(15);
    __m256i carry = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 2 * VECTOR <= count; i += 2 * VECTOR) {
        __m256i x = _mm256_loadu_si256((const __m256i *)(row + i));
        x = _mm256_add_epi8(x, _mm256_slli_si256(x, 1));
        x = _mm256_add_epi8(x, _mm256_slli_si256(x, 2));
        x = _mm256_add_epi8(x, _mm256_slli_si256(x, 4));
        x = _mm256_add_epi8(x, _mm256_slli_si256(x, 8));
        __m256i lasts = _mm256_shuffle_epi8(x, end);
        x = _mm256_add_epi8(x, _mm256_permute2x128_si256(lasts, lasts, 0x08));
        lasts = _mm256_shuffle_epi8(x, end);
        __m256i total = _mm256_permute2x128_si256(lasts, lasts, 0x11);
        _mm256_storeu_si256((__m256i *)(row + i), _mm256_add_epi8(x, carry));
        carry = _mm256_add_epi8(carry, total);
    }
    rest(row, i, count, (uint8_t)_mm_cvtsi128_si32(_mm256_castsi256_si128(carry)));
}

static void sums(uint8_t *row, size_t count, int tier) {
    if (tier >= KMAP_TIER_AVX2) {
        sums_avx2(row, count);
    } else if (tier >= KMAP_TIER_SSSE3) {
        sums_ssse3(row, count);
    } else {
        sums_sse2(row, count);
    }
}

#endif

// 1 byte from each plane makes a sample, the first plane its most significant byte.
// Starts at sample `s`. On x86 nothing here is past SSE2.
static inline void gather(const uint8_t *row, size_t width, float *out, size_t s) {
    const uint8_t *p0 = row, *p1 = row + width, *p2 = row + 2 * width, *p3 = row + 3 * width;
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

#if defined(KMAP_SSE)

// 32 samples at a time. The unpacking works within each half of a register, so the
// halves come out crossed and are put back in order on the way out.
KMAP_AVX2
static void gather_avx2(const uint8_t *row, size_t width, float *out) {
    const uint8_t *p0 = row, *p1 = row + width, *p2 = row + 2 * width, *p3 = row + 3 * width;
    size_t s = 0;
    for (; s + 2 * VECTOR <= width; s += 2 * VECTOR) {
        __m256i b3 = _mm256_loadu_si256((const __m256i *)(p3 + s));
        __m256i b2 = _mm256_loadu_si256((const __m256i *)(p2 + s));
        __m256i b1 = _mm256_loadu_si256((const __m256i *)(p1 + s));
        __m256i b0 = _mm256_loadu_si256((const __m256i *)(p0 + s));
        __m256i low32 = _mm256_unpacklo_epi8(b3, b2), high32 = _mm256_unpackhi_epi8(b3, b2);
        __m256i low10 = _mm256_unpacklo_epi8(b1, b0), high10 = _mm256_unpackhi_epi8(b1, b0);
        __m256i u0 = _mm256_unpacklo_epi16(low32, low10), u1 = _mm256_unpackhi_epi16(low32, low10);
        __m256i u2 = _mm256_unpacklo_epi16(high32, high10), u3 = _mm256_unpackhi_epi16(high32, high10);
        __m256i *to = (__m256i *)(out + s);
        _mm256_storeu_si256(to, _mm256_permute2x128_si256(u0, u1, 0x20));
        _mm256_storeu_si256(to + 1, _mm256_permute2x128_si256(u2, u3, 0x20));
        _mm256_storeu_si256(to + 2, _mm256_permute2x128_si256(u0, u1, 0x31));
        _mm256_storeu_si256(to + 3, _mm256_permute2x128_si256(u2, u3, 0x31));
    }
    gather(row, width, out, s);
}

#endif

int kmap_float_rows(uint8_t *raw, size_t width, size_t rows, float *out) {
    int tier = kmap_vector_tier();
    if (tier == KMAP_TIER_NONE) return 0;
    for (size_t r = 0; r < rows; r++) {
        uint8_t *row = raw + r * width * 4;
        sums(row, width * 4, tier);
#if defined(KMAP_SSE)
        if (tier >= KMAP_TIER_AVX2) {
            gather_avx2(row, width, out + r * width);
            continue;
        }
#endif
        gather(row, width, out + r * width, 0);
    }
    return 1;
}

#else

int kmap_float_rows(uint8_t *raw, size_t width, size_t rows, float *out) {
    (void)raw; (void)width; (void)rows; (void)out;
    return 0;
}

#endif
