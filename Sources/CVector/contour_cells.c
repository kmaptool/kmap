#include "contour_cells.h"

#include <string.h>

#include "vector_support.h"

// 1 cell, as the vector loops judge it.
static inline uint64_t mark(const int16_t *top, const int16_t *bottom, const int32_t *band_top,
                            const int32_t *band_bottom, size_t c, int16_t floor) {
    int ground = top[c] > floor && top[c + 1] > floor && bottom[c] > floor && bottom[c + 1] > floor;
    int32_t b = band_top[c];
    int spans = band_top[c + 1] != b || band_bottom[c] != b || band_bottom[c + 1] != b;
    return (uint64_t)(ground && spans);
}

#if defined(KMAP_NEON)

// 8 cells: the 4 corners' band masks narrowed to bytes, and 1 bit a byte gathered.
static inline unsigned marks8(const int16_t *top, const int16_t *bottom, const int32_t *band_top,
                             const int32_t *band_bottom, size_t c, int16_t floor) {
    const int16x8_t limit = vdupq_n_s16(floor);
    int16x8_t lowest = vminq_s16(vminq_s16(vld1q_s16(top + c), vld1q_s16(top + c + 1)),
                                 vminq_s16(vld1q_s16(bottom + c), vld1q_s16(bottom + c + 1)));
    uint16x8_t above = vcgtq_s16(lowest, limit);
    uint32x4_t same[2];
    for (int h = 0; h < 2; h++) {
        size_t at = c + 4 * (size_t)h;
        int32x4_t b = vld1q_s32(band_top + at);
        same[h] = vandq_u32(vandq_u32(vceqq_s32(b, vld1q_s32(band_top + at + 1)), vceqq_s32(b, vld1q_s32(band_bottom + at))),
                            vceqq_s32(b, vld1q_s32(band_bottom + at + 1)));
    }
    uint16x8_t spans = vmvnq_u16(vcombine_u16(vmovn_u32(same[0]), vmovn_u32(same[1])));
    uint8x8_t marked = vmovn_u16(vandq_u16(above, spans));
    const uint8x8_t weights = {1, 2, 4, 8, 16, 32, 64, 128};
    return vaddv_u8(vand_u8(marked, weights));
}

#elif defined(KMAP_SSE)

// SSE2 has no 32-bit minimum or maximum, so the bands are compared for equality.
static inline unsigned marks8(const int16_t *top, const int16_t *bottom, const int32_t *band_top,
                             const int32_t *band_bottom, size_t c, int16_t floor) {
#define LOAD(p) _mm_loadu_si128((const __m128i *)(p))
    __m128i lowest = _mm_min_epi16(_mm_min_epi16(LOAD(top + c), LOAD(top + c + 1)),
                                   _mm_min_epi16(LOAD(bottom + c), LOAD(bottom + c + 1)));
    __m128i above = _mm_cmpgt_epi16(lowest, _mm_set1_epi16(floor));
    __m128i same[2];
    for (int h = 0; h < 2; h++) {
        size_t at = c + 4 * (size_t)h;
        __m128i b = LOAD(band_top + at);
        same[h] = _mm_and_si128(_mm_and_si128(_mm_cmpeq_epi32(b, LOAD(band_top + at + 1)), _mm_cmpeq_epi32(b, LOAD(band_bottom + at))),
                                _mm_cmpeq_epi32(b, LOAD(band_bottom + at + 1)));
    }
#undef LOAD
    __m128i spans = _mm_andnot_si128(_mm_packs_epi32(same[0], same[1]), above);
    return (unsigned)_mm_movemask_epi8(_mm_packs_epi16(spans, _mm_setzero_si128()));
}

#endif

void kmap_contour_cells(const int16_t *top, const int16_t *bottom, const int32_t *band_top,
                        const int32_t *band_bottom, size_t cells, int16_t floor, uint64_t *marks) {
    memset(marks, 0, (cells + 63) / 64 * sizeof *marks);
    size_t c = 0;
#if defined(KMAP_NEON) || defined(KMAP_SSE)
    if (kmap_vector_tier() != KMAP_TIER_NONE) {
        for (; c + 8 <= cells; c += 8) {
            marks[c / 64] |= (uint64_t)marks8(top, bottom, band_top, band_bottom, c, floor) << (c % 64);
        }
    }
#endif
    for (; c < cells; c++) marks[c / 64] |= mark(top, bottom, band_top, band_bottom, c, floor) << (c % 64);
}
