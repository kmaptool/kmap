#include "elevation_rows.h"

#include <math.h>
#include <string.h>

#include "vector_support.h"

#if defined(KMAP_NEON) || defined(KMAP_SSE)

// What a vector loop left of a row, 1 word at a time, the sum so far in `carry`.
static void words_rest(const uint8_t *row, size_t i, size_t width, uint32_t carry, float *out) {
    for (; i < width; i++) {
        uint32_t word;
        memcpy(&word, row + 4 * i, 4);
        carry += word;
        memcpy(out + i, &carry, 4);
    }
}

// The vector loops' rules, 1 height at a time; round() rounds half away from zero.
static int64_t heights_rest_f64(const double *in, size_t i, size_t count, uint8_t *out) {
    int64_t stored = 0;
    for (; i < count; i++) {
        double h = in[i];
        int16_t m = 0;
        if (fabs(h) < INFINITY) {
            m = (int16_t)round(h < -32768.0 ? -32768.0 : (h > 32767.0 ? 32767.0 : h));
            stored++;
        }
        out[2 * i] = (uint8_t)((uint16_t)m >> 8);
        out[2 * i + 1] = (uint8_t)m;
    }
    return stored;
}

static int64_t heights_rest_f32(const float *in, size_t i, size_t count, float nodata, int has_nodata, uint8_t *out) {
    int64_t stored = 0;
    for (; i < count; i++) {
        float h = in[i];
        int16_t m = 0;
        if (fabsf(h) < INFINITY && !(has_nodata && h == nodata)) {
            m = (int16_t)roundf(h < -32768.0f ? -32768.0f : (h > 32767.0f ? 32767.0f : h));
            stored++;
        }
        out[2 * i] = (uint8_t)((uint16_t)m >> 8);
        out[2 * i + 1] = (uint8_t)m;
    }
    return stored;
}

#if defined(KMAP_NEON)

// Running sum of a row, 8 words at a time. The block total is taken before the carry
// is added, so the carry waits for 1 addition per block.
static void word_row(const uint8_t *row, size_t width, float *out, int tier) {
    (void)tier;
    const uint32x4_t zero = vdupq_n_u32(0);
    uint32x4_t carry = zero;
    size_t i = 0;
    for (; i + 8 <= width; i += 8) {
        uint32x4_t a = vreinterpretq_u32_u8(vld1q_u8(row + 4 * i));
        uint32x4_t b = vreinterpretq_u32_u8(vld1q_u8(row + 4 * i + 16));
        a = vaddq_u32(a, vextq_u32(zero, a, 3));
        b = vaddq_u32(b, vextq_u32(zero, b, 3));
        a = vaddq_u32(a, vextq_u32(zero, a, 2));
        b = vaddq_u32(b, vextq_u32(zero, b, 2));
        b = vaddq_u32(b, vdupq_laneq_u32(a, 3));
        vst1q_f32(out + i, vreinterpretq_f32_u32(vaddq_u32(a, carry)));
        vst1q_f32(out + i + 4, vreinterpretq_f32_u32(vaddq_u32(b, carry)));
        carry = vaddq_u32(carry, vdupq_laneq_u32(b, 3));
    }
    words_rest(row, i, width, vgetq_lane_u32(carry, 0), out);
}

// 8 heights at a time. vcvta rounds half away from zero; |h| < inf rejects NaN too.
static int64_t heights_f64(const double *in, size_t count, uint8_t *out, int tier) {
    (void)tier;
    const float64x2_t lo = vdupq_n_f64(-32768.0), hi = vdupq_n_f64(32767.0), inf = vdupq_n_f64(INFINITY);
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        int32x4_t v[2];
        uint32x4_t m[2];
        for (int k = 0; k < 2; k++) {
            float64x2_t a = vld1q_f64(in + i + 4 * k), b = vld1q_f64(in + i + 4 * k + 2);
            uint64x2_t ma = vcaltq_f64(a, inf), mb = vcaltq_f64(b, inf);
            int64x2_t ra = vcvtaq_s64_f64(vminq_f64(vmaxq_f64(a, lo), hi));
            int64x2_t rb = vcvtaq_s64_f64(vminq_f64(vmaxq_f64(b, lo), hi));
            v[k] = vcombine_s32(vmovn_s64(ra), vmovn_s64(rb));
            m[k] = vcombine_u32(vmovn_u64(ma), vmovn_u64(mb));
        }
        uint16x8_t mask = vcombine_u16(vmovn_u32(m[0]), vmovn_u32(m[1]));
        uint16x8_t r = vreinterpretq_u16_s16(vcombine_s16(vmovn_s32(v[0]), vmovn_s32(v[1])));
        vst1q_u8(out + 2 * i, vrev16q_u8(vreinterpretq_u8_u16(vandq_u16(r, mask))));
        stored += vaddvq_u16(vshrq_n_u16(mask, 15));
    }
    return stored + heights_rest_f64(in, i, count, out);
}

static int64_t heights_f32(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out, int tier) {
    (void)tier;
    const float32x4_t lo = vdupq_n_f32(-32768.0f), hi = vdupq_n_f32(32767.0f), inf = vdupq_n_f32(INFINITY);
    const float32x4_t hole = vdupq_n_f32(nodata);
    const uint32x4_t holes = vdupq_n_u32(has_nodata ? 0xFFFFFFFFu : 0);
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        float32x4_t a = vld1q_f32(in + i), b = vld1q_f32(in + i + 4);
        uint32x4_t ma = vbicq_u32(vcaltq_f32(a, inf), vandq_u32(vceqq_f32(a, hole), holes));
        uint32x4_t mb = vbicq_u32(vcaltq_f32(b, inf), vandq_u32(vceqq_f32(b, hole), holes));
        int32x4_t ra = vcvtaq_s32_f32(vminq_f32(vmaxq_f32(a, lo), hi));
        int32x4_t rb = vcvtaq_s32_f32(vminq_f32(vmaxq_f32(b, lo), hi));
        uint16x8_t mask = vcombine_u16(vmovn_u32(ma), vmovn_u32(mb));
        uint16x8_t r = vreinterpretq_u16_s16(vcombine_s16(vmovn_s32(ra), vmovn_s32(rb)));
        vst1q_u8(out + 2 * i, vrev16q_u8(vreinterpretq_u8_u16(vandq_u16(r, mask))));
        stored += vaddvq_u16(vshrq_n_u16(mask, 15));
    }
    return stored + heights_rest_f32(in, i, count, nodata, has_nodata, out);
}

#else

static void word_row_sse2(const uint8_t *row, size_t width, float *out) {
    __m128i carry = _mm_setzero_si128();
    size_t i = 0;
    for (; i + 8 <= width; i += 8) {
        __m128i a = _mm_loadu_si128((const __m128i *)(row + 4 * i));
        __m128i b = _mm_loadu_si128((const __m128i *)(row + 4 * i + 16));
        a = _mm_add_epi32(a, _mm_slli_si128(a, 4));
        b = _mm_add_epi32(b, _mm_slli_si128(b, 4));
        a = _mm_add_epi32(a, _mm_slli_si128(a, 8));
        b = _mm_add_epi32(b, _mm_slli_si128(b, 8));
        b = _mm_add_epi32(b, _mm_shuffle_epi32(a, 0xFF));
        _mm_storeu_si128((__m128i *)(out + i), _mm_add_epi32(a, carry));
        _mm_storeu_si128((__m128i *)(out + i + 4), _mm_add_epi32(b, carry));
        carry = _mm_add_epi32(carry, _mm_shuffle_epi32(b, 0xFF));
    }
    words_rest(row, i, width, (uint32_t)_mm_cvtsi128_si32(carry), out);
}

// 8 words in 1 register: the low half's last word is added to the high half.
KMAP_AVX2
static void word_row_avx2(const uint8_t *row, size_t width, float *out) {
    const __m256i last = _mm256_set1_epi32(7);
    __m256i carry = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 8 <= width; i += 8) {
        __m256i x = _mm256_loadu_si256((const __m256i *)(row + 4 * i));
        x = _mm256_add_epi32(x, _mm256_slli_si256(x, 4));
        x = _mm256_add_epi32(x, _mm256_slli_si256(x, 8));
        __m256i lasts = _mm256_shuffle_epi32(x, 0xFF);
        x = _mm256_add_epi32(x, _mm256_permute2x128_si256(lasts, lasts, 0x08));
        __m256i total = _mm256_permutevar8x32_epi32(x, last);
        _mm256_storeu_si256((__m256i *)(out + i), _mm256_add_epi32(x, carry));
        carry = _mm256_add_epi32(carry, total);
    }
    words_rest(row, i, width, (uint32_t)_mm_cvtsi128_si32(_mm256_castsi256_si128(carry)), out);
}

static void word_row(const uint8_t *row, size_t width, float *out, int tier) {
    if (tier >= KMAP_TIER_AVX2) {
        word_row_avx2(row, width, out);
    } else {
        word_row_sse2(row, width, out);
    }
}

// SSE cannot round half away from zero: truncate, then step by the exact remainder.
static inline __m128i away_pd(__m128d x) {
    __m128i t = _mm_cvttpd_epi32(x);
    __m128d cut = _mm_sub_pd(x, _mm_cvtepi32_pd(t));
    __m128i up = _mm_shuffle_epi32(_mm_castpd_si128(_mm_cmpge_pd(cut, _mm_set1_pd(0.5))), 0x08);
    __m128i down = _mm_shuffle_epi32(_mm_castpd_si128(_mm_cmple_pd(cut, _mm_set1_pd(-0.5))), 0x08);
    return _mm_add_epi32(_mm_sub_epi32(t, up), down);
}

// 2 heights: their rounded values and whether each is finite, in the low 2 lanes.
static inline void two_pd(const double *in, __m128i *value, __m128i *mask) {
    const __m128d lo = _mm_set1_pd(-32768.0), hi = _mm_set1_pd(32767.0), inf = _mm_set1_pd(INFINITY);
    const __m128d magnitude = _mm_castsi128_pd(_mm_set1_epi64x(0x7FFFFFFFFFFFFFFFLL));
    __m128d x = _mm_loadu_pd(in);
    *mask = _mm_shuffle_epi32(_mm_castpd_si128(_mm_cmplt_pd(_mm_and_pd(x, magnitude), inf)), 0x08);
    *value = away_pd(_mm_min_pd(_mm_max_pd(x, lo), hi));
}

// 8 16-bit lanes kept where `mask`, big-endian, and how many were kept.
static inline int store_be16(uint8_t *out, __m128i value, __m128i mask) {
    value = _mm_and_si128(value, mask);
    _mm_storeu_si128((__m128i *)out, _mm_or_si128(_mm_slli_epi16(value, 8), _mm_srli_epi16(value, 8)));
    return __builtin_popcount((unsigned)_mm_movemask_epi8(mask)) / 2;
}

static int64_t heights_f64_sse2(const double *in, size_t count, uint8_t *out) {
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        __m128i v[4], m[4];
        for (int k = 0; k < 4; k++) two_pd(in + i + 2 * k, &v[k], &m[k]);
        __m128i value = _mm_packs_epi32(_mm_unpacklo_epi64(v[0], v[1]), _mm_unpacklo_epi64(v[2], v[3]));
        __m128i mask = _mm_packs_epi32(_mm_unpacklo_epi64(m[0], m[1]), _mm_unpacklo_epi64(m[2], m[3]));
        stored += store_be16(out + 2 * i, value, mask);
    }
    return stored + heights_rest_f64(in, i, count, out);
}

// 4 heights; masks of 64 bits brought down to 32 with lanes 0, 2, 4 and 6.
KMAP_AVX2
static inline void four_pd(const double *in, __m128i *value, __m128i *mask) {
    const __m256d lo = _mm256_set1_pd(-32768.0), hi = _mm256_set1_pd(32767.0), inf = _mm256_set1_pd(INFINITY);
    const __m256d magnitude = _mm256_castsi256_pd(_mm256_set1_epi64x(0x7FFFFFFFFFFFFFFFLL));
    const __m256i even = _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6);
    __m256d x = _mm256_loadu_pd(in);
    __m256d finite = _mm256_cmp_pd(_mm256_and_pd(x, magnitude), inf, _CMP_LT_OQ);
    *mask = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(_mm256_castpd_si256(finite), even));
    x = _mm256_min_pd(_mm256_max_pd(x, lo), hi);
    __m128i t = _mm256_cvttpd_epi32(x);
    __m256d cut = _mm256_sub_pd(x, _mm256_cvtepi32_pd(t));
    __m256d up = _mm256_cmp_pd(cut, _mm256_set1_pd(0.5), _CMP_GE_OQ);
    __m256d down = _mm256_cmp_pd(cut, _mm256_set1_pd(-0.5), _CMP_LE_OQ);
    __m128i up32 = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(_mm256_castpd_si256(up), even));
    __m128i down32 = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(_mm256_castpd_si256(down), even));
    *value = _mm_add_epi32(_mm_sub_epi32(t, up32), down32);
}

KMAP_AVX2
static int64_t heights_f64_avx2(const double *in, size_t count, uint8_t *out) {
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        __m128i v0, m0, v1, m1;
        four_pd(in + i, &v0, &m0);
        four_pd(in + i + 4, &v1, &m1);
        stored += store_be16(out + 2 * i, _mm_packs_epi32(v0, v1), _mm_packs_epi32(m0, m1));
    }
    return stored + heights_rest_f64(in, i, count, out);
}

static int64_t heights_f64(const double *in, size_t count, uint8_t *out, int tier) {
    return tier >= KMAP_TIER_AVX2 ? heights_f64_avx2(in, count, out) : heights_f64_sse2(in, count, out);
}

// 4 heights as rounded values and a mask of those finite and not nodata.
static inline void four_ps(const float *in, float nodata, int has_nodata, __m128i *value, __m128i *mask) {
    const __m128 lo = _mm_set1_ps(-32768.0f), hi = _mm_set1_ps(32767.0f), inf = _mm_set1_ps(INFINITY);
    const __m128 magnitude = _mm_castsi128_ps(_mm_set1_epi32(0x7FFFFFFF));
    __m128 x = _mm_loadu_ps(in);
    __m128 keep = _mm_cmplt_ps(_mm_and_ps(x, magnitude), inf);
    if (has_nodata) keep = _mm_and_ps(keep, _mm_cmpneq_ps(x, _mm_set1_ps(nodata)));
    *mask = _mm_castps_si128(keep);
    x = _mm_min_ps(_mm_max_ps(x, lo), hi);
    __m128i t = _mm_cvttps_epi32(x);
    __m128 cut = _mm_sub_ps(x, _mm_cvtepi32_ps(t));
    __m128i up = _mm_castps_si128(_mm_cmpge_ps(cut, _mm_set1_ps(0.5f)));
    __m128i down = _mm_castps_si128(_mm_cmple_ps(cut, _mm_set1_ps(-0.5f)));
    *value = _mm_add_epi32(_mm_sub_epi32(t, up), down);
}

static int64_t heights_f32_sse2(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out) {
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        __m128i v0, m0, v1, m1;
        four_ps(in + i, nodata, has_nodata, &v0, &m0);
        four_ps(in + i + 4, nodata, has_nodata, &v1, &m1);
        stored += store_be16(out + 2 * i, _mm_packs_epi32(v0, v1), _mm_packs_epi32(m0, m1));
    }
    return stored + heights_rest_f32(in, i, count, nodata, has_nodata, out);
}

// 16 at a time; packing works per 128-bit half, so the halves are reordered before the store.
KMAP_AVX2
static int64_t heights_f32_avx2(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out) {
    const __m256 lo = _mm256_set1_ps(-32768.0f), hi = _mm256_set1_ps(32767.0f), inf = _mm256_set1_ps(INFINITY);
    const __m256 magnitude = _mm256_castsi256_ps(_mm256_set1_epi32(0x7FFFFFFF));
    const __m256 hole = _mm256_set1_ps(nodata);
    int64_t stored = 0;
    size_t i = 0;
    for (; i + 16 <= count; i += 16) {
        __m256i v[2], m[2];
        for (int k = 0; k < 2; k++) {
            __m256 x = _mm256_loadu_ps(in + i + 8 * k);
            __m256 keep = _mm256_cmp_ps(_mm256_and_ps(x, magnitude), inf, _CMP_LT_OQ);
            if (has_nodata) keep = _mm256_and_ps(keep, _mm256_cmp_ps(x, hole, _CMP_NEQ_UQ));
            m[k] = _mm256_castps_si256(keep);
            x = _mm256_min_ps(_mm256_max_ps(x, lo), hi);
            __m256i t = _mm256_cvttps_epi32(x);
            __m256 cut = _mm256_sub_ps(x, _mm256_cvtepi32_ps(t));
            __m256i up = _mm256_castps_si256(_mm256_cmp_ps(cut, _mm256_set1_ps(0.5f), _CMP_GE_OQ));
            __m256i down = _mm256_castps_si256(_mm256_cmp_ps(cut, _mm256_set1_ps(-0.5f), _CMP_LE_OQ));
            v[k] = _mm256_add_epi32(_mm256_sub_epi32(t, up), down);
        }
        __m256i value = _mm256_permute4x64_epi64(_mm256_packs_epi32(v[0], v[1]), 0xD8);
        __m256i mask = _mm256_permute4x64_epi64(_mm256_packs_epi32(m[0], m[1]), 0xD8);
        value = _mm256_and_si256(value, mask);
        value = _mm256_or_si256(_mm256_slli_epi16(value, 8), _mm256_srli_epi16(value, 8));
        _mm256_storeu_si256((__m256i *)(out + 2 * i), value);
        stored += __builtin_popcount((unsigned)_mm256_movemask_epi8(mask)) / 2;
    }
    return stored + heights_f32_sse2(in + i, count - i, nodata, has_nodata, out + 2 * i);
}

static int64_t heights_f32(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out, int tier) {
    return tier >= KMAP_TIER_AVX2 ? heights_f32_avx2(in, count, nodata, has_nodata, out)
                                  : heights_f32_sse2(in, count, nodata, has_nodata, out);
}

#endif

int kmap_word_rows(const uint8_t *raw, size_t width, size_t rows, int differenced, float *out) {
    int tier = kmap_vector_tier();
    if (tier == KMAP_TIER_NONE) return 0;
    if (!differenced) {
        memcpy(out, raw, width * rows * 4);
        return 1;
    }
    for (size_t r = 0; r < rows; r++) word_row(raw + r * width * 4, width, out + r * width, tier);
    return 1;
}

int64_t kmap_heights_f64(const double *in, size_t count, uint8_t *out) {
    int tier = kmap_vector_tier();
    if (tier == KMAP_TIER_NONE) return -1;
    return heights_f64(in, count, out, tier);
}

int64_t kmap_heights_f32(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out) {
    int tier = kmap_vector_tier();
    if (tier == KMAP_TIER_NONE) return -1;
    return heights_f32(in, count, nodata, has_nodata, out, tier);
}

#else

int kmap_word_rows(const uint8_t *raw, size_t width, size_t rows, int differenced, float *out) {
    (void)raw; (void)width; (void)rows; (void)differenced; (void)out;
    return 0;
}

int64_t kmap_heights_f64(const double *in, size_t count, uint8_t *out) {
    (void)in; (void)count; (void)out;
    return -1;
}

int64_t kmap_heights_f32(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out) {
    (void)in; (void)count; (void)nodata; (void)has_nodata; (void)out;
    return -1;
}

#endif
