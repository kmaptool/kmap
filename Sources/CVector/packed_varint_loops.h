// The decoder's loops, compiled once for each set of instructions. Not a header to
// include for its declarations: packed_varint.c includes it with these defined.
//
//   SUFFIX          what the names here end in
//   TARGET          the attribute that compiles a function for the instructions
//   WITH_SHUFFLE    where a byte shuffle by a table exists: NEON, SSSE3 and up
//   WITH_WIDENING   on x86, where 1 instruction widens a lane: SSE4.1 and up
//   WITH_AVX2       on x86, where the widening and the gathering of bits go 32 bytes
//                   at a time
//
// Without a shuffle only runs of 1-byte values go a vector at a time, and the rest
// a byte at a time.

#if defined(KMAP_NEON)

static inline bytes16 NAME(load)(const uint8_t *p) { return vld1q_u8(p); }

// The continuation bits of 64 bytes, 1 bit a byte.
static inline uint64_t NAME(continuations)(const uint8_t *p) {
    const uint8x16_t weights = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
    uint8x16_t a = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p))), weights);
    uint8x16_t b = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 16))), weights);
    uint8x16_t c = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 32))), weights);
    uint8x16_t d = vandq_u8(vcltzq_s8(vreinterpretq_s8_u8(vld1q_u8(p + 48))), weights);
    uint8x16_t sum = vpaddq_u8(vpaddq_u8(a, b), vpaddq_u8(c, d));
    return vgetq_lane_u64(vreinterpretq_u64_u8(vpaddq_u8(sum, sum)), 0);
}

static inline bytes16 NAME(shuffled)(bytes16 bytes, const uint8_t *shuffle) {
    return vqtbl1q_u8(bytes, vld1q_u8(shuffle));
}

// The 7-bit groups of each byte pair joined into 14 bits, then of each 16-bit pair into
// 28: a shift and an insert each time, instead of a shift and a mask per byte.
static inline uint32x4_t NAME(joined28)(bytes16 lanes) {
    uint16x8_t a = vreinterpretq_u16_u8(vandq_u8(lanes, vdupq_n_u8(0x7F)));
    a = vsliq_n_u16(a, vshrq_n_u16(a, 8), 7);
    uint32x4_t b = vreinterpretq_u32_u16(a);
    return vsliq_n_u32(b, vshrq_n_u32(b, 16), 14);
}

// 4 lanes of up to 4 bytes each, as their values.
static inline uint32x4_t NAME(quads)(bytes16 lanes) { return NAME(joined28)(lanes); }

// 2 lanes of up to 8 bytes each, as their values.
static inline uint64x2_t NAME(pairs)(bytes16 lanes) {
    uint64x2_t c = vreinterpretq_u64_u32(NAME(joined28)(lanes));
    return vsliq_n_u64(c, vshrq_n_u64(c, 32), 28);
}

static inline void NAME(zigzagBytes)(bytes16 bytes, int64_t *o) {
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

static inline void NAME(zigzagQuads)(bytes16 lanes, int64_t *o) {
    uint32x4_t v = NAME(quads)(lanes);
    int32x4_t z = veorq_s32(
        vreinterpretq_s32_u32(vshrq_n_u32(v, 1)),
        vnegq_s32(vreinterpretq_s32_u32(vandq_u32(v, vdupq_n_u32(1)))));
    vst1q_s64(o, vmovl_s32(vget_low_s32(z)));
    vst1q_s64(o + 2, vmovl_s32(vget_high_s32(z)));
}

static inline void NAME(zigzagPairs)(bytes16 lanes, int64_t *o) {
    uint64x2_t v = NAME(pairs)(lanes);
    vst1q_s64(o, veorq_s64(
        vreinterpretq_s64_u64(vshrq_n_u64(v, 1)),
        vnegq_s64(vreinterpretq_s64_u64(vandq_u64(v, vdupq_n_u64(1))))));
}

static inline void NAME(lowBytes)(bytes16 bytes, int32_t *o) {
    uint16x8_t a = vmovl_u8(vget_low_u8(bytes)), b = vmovl_u8(vget_high_u8(bytes));
    vst1q_s32(o, vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(a))));
    vst1q_s32(o + 4, vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(a))));
    vst1q_s32(o + 8, vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(b))));
    vst1q_s32(o + 12, vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(b))));
}

static inline void NAME(lowQuads)(bytes16 lanes, int32_t *o) {
    vst1q_s32(o, vreinterpretq_s32_u32(NAME(quads)(lanes)));
}

static inline void NAME(lowPairs)(bytes16 lanes, int32_t *o) {
    vst1_s32(o, vreinterpret_s32_u32(vmovn_u64(NAME(pairs)(lanes))));
}

#else  // KMAP_SSE

TARGET
static inline bytes16 NAME(load)(const uint8_t *p) { return _mm_loadu_si128((const __m128i *)p); }

// The continuation bits of 64 bytes, 1 bit a byte.
TARGET
static inline uint64_t NAME(continuations)(const uint8_t *p) {
#if defined(WITH_AVX2)
    uint64_t low = (uint32_t)_mm256_movemask_epi8(_mm256_loadu_si256((const __m256i *)p));
    uint64_t high = (uint32_t)_mm256_movemask_epi8(_mm256_loadu_si256((const __m256i *)(p + 32)));
    return low | high << 32;
#else
    uint64_t a = (uint32_t)_mm_movemask_epi8(NAME(load)(p));
    uint64_t b = (uint32_t)_mm_movemask_epi8(NAME(load)(p + 16));
    uint64_t c = (uint32_t)_mm_movemask_epi8(NAME(load)(p + 32));
    uint64_t d = (uint32_t)_mm_movemask_epi8(NAME(load)(p + 48));
    return a | b << 16 | c << 32 | d << 48;
#endif
}

// 4 signed 32-bit lanes stored as 4 of 64 bits.
TARGET
static inline void NAME(store64)(__m128i lanes, int64_t *o) {
#if defined(WITH_AVX2)
    _mm256_storeu_si256((__m256i *)o, _mm256_cvtepi32_epi64(lanes));
#elif defined(WITH_WIDENING)
    _mm_storeu_si128((__m128i *)o, _mm_cvtepi32_epi64(lanes));
    _mm_storeu_si128((__m128i *)(o + 2), _mm_cvtepi32_epi64(_mm_srli_si128(lanes, 8)));
#else
    // A lane beside its own sign is the lane widened.
    __m128i sign = _mm_srai_epi32(lanes, 31);
    _mm_storeu_si128((__m128i *)o, _mm_unpacklo_epi32(lanes, sign));
    _mm_storeu_si128((__m128i *)(o + 2), _mm_unpackhi_epi32(lanes, sign));
#endif
}

TARGET
static inline void NAME(zigzagBytes)(bytes16 bytes, int64_t *o) {
    // There is no shift of bytes: pairs are shifted, and the bit that crosses into
    // the lower byte is masked off.
    __m128i z = _mm_xor_si128(
        _mm_and_si128(_mm_srli_epi16(bytes, 1), _mm_set1_epi8(0x7F)),
        _mm_sub_epi8(_mm_setzero_si128(), _mm_and_si128(bytes, _mm_set1_epi8(1))));
#if defined(WITH_AVX2)
    for (int i = 0; i < 4; i++) {
        _mm256_storeu_si256((__m256i *)(o + 4 * i), _mm256_cvtepi8_epi64(z));
        z = _mm_srli_si128(z, 4);
    }
#elif defined(WITH_WIDENING)
    for (int i = 0; i < 8; i++) {
        _mm_storeu_si128((__m128i *)(o + 2 * i), _mm_cvtepi8_epi64(z));
        z = _mm_srli_si128(z, 2);
    }
#else
    __m128i sign = _mm_cmpgt_epi8(_mm_setzero_si128(), z);
    __m128i low = _mm_unpacklo_epi8(z, sign), high = _mm_unpackhi_epi8(z, sign);
    __m128i lowSign = _mm_srai_epi16(low, 15), highSign = _mm_srai_epi16(high, 15);
    NAME(store64)(_mm_unpacklo_epi16(low, lowSign), o);
    NAME(store64)(_mm_unpackhi_epi16(low, lowSign), o + 4);
    NAME(store64)(_mm_unpacklo_epi16(high, highSign), o + 8);
    NAME(store64)(_mm_unpackhi_epi16(high, highSign), o + 12);
#endif
}

TARGET
static inline void NAME(lowBytes)(bytes16 bytes, int32_t *o) {
#if defined(WITH_AVX2)
    _mm256_storeu_si256((__m256i *)o, _mm256_cvtepu8_epi32(bytes));
    _mm256_storeu_si256((__m256i *)(o + 8), _mm256_cvtepu8_epi32(_mm_srli_si128(bytes, 8)));
#elif defined(WITH_WIDENING)
    _mm_storeu_si128((__m128i *)o, _mm_cvtepu8_epi32(bytes));
    _mm_storeu_si128((__m128i *)(o + 4), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 4)));
    _mm_storeu_si128((__m128i *)(o + 8), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 8)));
    _mm_storeu_si128((__m128i *)(o + 12), _mm_cvtepu8_epi32(_mm_srli_si128(bytes, 12)));
#else
    const __m128i zero = _mm_setzero_si128();
    __m128i low = _mm_unpacklo_epi8(bytes, zero), high = _mm_unpackhi_epi8(bytes, zero);
    _mm_storeu_si128((__m128i *)o, _mm_unpacklo_epi16(low, zero));
    _mm_storeu_si128((__m128i *)(o + 4), _mm_unpackhi_epi16(low, zero));
    _mm_storeu_si128((__m128i *)(o + 8), _mm_unpacklo_epi16(high, zero));
    _mm_storeu_si128((__m128i *)(o + 12), _mm_unpackhi_epi16(high, zero));
#endif
}

#if defined(WITH_SHUFFLE)

TARGET
static inline bytes16 NAME(shuffled)(bytes16 bytes, const uint8_t *shuffle) {
    return _mm_shuffle_epi8(bytes, NAME(load)(shuffle));
}

// The 7-bit groups of each byte pair joined into 14 bits, then of each 16-bit pair into
// 28, by multiply-add: 1 and 128 on the bytes, 1 and 16384 on the halves. Neither
// product overflows: 127 + 127 * 128 and 16383 + 16383 * 16384 fit their lanes.
TARGET
static inline __m128i NAME(joined28)(bytes16 l) {
    __m128i bytes = _mm_and_si128(l, _mm_set1_epi8(0x7F));
    __m128i halves = _mm_maddubs_epi16(_mm_set1_epi16((short)0x8001), bytes);
    return _mm_madd_epi16(halves, _mm_set1_epi32(0x40000001));
}

// 4 lanes of up to 4 bytes each, as their values.
TARGET
static inline __m128i NAME(quads)(bytes16 l) { return NAME(joined28)(l); }

// 2 lanes of up to 8 bytes each, as their values.
TARGET
static inline __m128i NAME(pairs)(bytes16 l) {
    __m128i v = NAME(joined28)(l);
    __m128i low = _mm_and_si128(v, _mm_set1_epi64x(0xFFFFFFFFLL));
    return _mm_or_si128(low, _mm_slli_epi64(_mm_srli_epi64(v, 32), 28));
}

TARGET
static inline void NAME(zigzagQuads)(bytes16 lanes, int64_t *o) {
    __m128i v = NAME(quads)(lanes);
    NAME(store64)(
        _mm_xor_si128(
            _mm_srli_epi32(v, 1),
            _mm_sub_epi32(_mm_setzero_si128(), _mm_and_si128(v, _mm_set1_epi32(1)))),
        o);
}

TARGET
static inline void NAME(zigzagPairs)(bytes16 lanes, int64_t *o) {
    __m128i v = NAME(pairs)(lanes);
    _mm_storeu_si128(
        (__m128i *)o,
        _mm_xor_si128(_mm_srli_epi64(v, 1), _mm_sub_epi64(_mm_setzero_si128(), _mm_and_si128(v, _mm_set1_epi64x(1)))));
}

TARGET
static inline void NAME(lowQuads)(bytes16 lanes, int32_t *o) { _mm_storeu_si128((__m128i *)o, NAME(quads)(lanes)); }

TARGET
static inline void NAME(lowPairs)(bytes16 lanes, int32_t *o) {
    // The low half of each 64-bit lane, side by side in the low 8 bytes.
    _mm_storel_epi64((__m128i *)o, _mm_shuffle_epi32(NAME(pairs)(lanes), _MM_SHUFFLE(3, 3, 2, 0)));
}

#endif  // WITH_SHUFFLE

#endif  // KMAP_SSE

// Lanes are stored whole, 4 or 2 at a time, and only the values among them are
// counted: the next store writes over the rest.

// What `k` values just written at `o` add up to, each replaced by the running total.
// Unsigned, so a corrupt stream wraps as the Swift sums do rather than overflowing.
#ifndef RUN_SUMS
#define RUN_SUMS(o, k)                                       \
    if (sum) {                                               \
        for (size_t j_ = 0; j_ < (size_t)(k); j_++) {        \
            total += (uint64_t)(o)[j_];                      \
            (o)[j_] = (int64_t)total;                        \
        }                                                    \
    }
#endif

// The zigzag loop, with the running sums where `sum` is given: each value is added
// while it is still in the cache, rather than in a second pass over the whole field.
TARGET
static inline __attribute__((always_inline)) size_t NAME(decode64)(
    const uint8_t *in, size_t count, int64_t *out, size_t *used, int64_t *sum) {
    const uint8_t *p = in, *end = in + count;
    int64_t *o = out;
    uint64_t total = sum ? (uint64_t)*sum : 0;
    while ((size_t)(end - p) >= CHUNK) {
        uint64_t bits = NAME(continuations)(p);
#if !defined(WITH_SHUFFLE)
        // A field of longer values gains nothing here and is left to the caller.
        if (!singles(bits)) break;
#endif
        const uint8_t *q = p, *last = p + (CHUNK - VECTOR);
        while (q <= last) {
            uint32_t ahead = (uint32_t)bits & 0xFFFF;
            if (ahead == 0) {
                NAME(zigzagBytes)(NAME(load)(q), o);
                RUN_SUMS(o, VECTOR)
                o += VECTOR;
                q += VECTOR;
                bits >>= VECTOR;
                continue;
            }
#if defined(WITH_SHUFFLE)
            unsigned pattern = ahead & (PATTERNS - 1);
            const Step *step = &steps[pattern];
            if (step->kind != ALONE) {
                bytes16 lanes = NAME(shuffled)(NAME(load)(q), shuffles[pattern]);
                if (step->kind == QUADS) {
                    NAME(zigzagQuads)(lanes, o);
                } else {
                    NAME(zigzagPairs)(lanes, o);
                }
                RUN_SUMS(o, step->values)
                o += step->values;
                q += step->taken;
                bits >>= step->taken;
                continue;
            }
#endif
            uint64_t raw;
            size_t length = alone(q, &raw);
            if (length == 0) {
                p = q;
                goto done;
            }
            *o = (int64_t)(raw >> 1) ^ -(int64_t)(raw & 1);
            RUN_SUMS(o, 1)
            o++;
            q += length;
            bits >>= length;
        }
        p = q;
    }
done:
    if (sum) *sum = (int64_t)total;
    *used = (size_t)(p - in);
    return (size_t)(o - out);
}

TARGET
static size_t NAME(zigzag64)(const uint8_t *in, size_t count, int64_t *out, size_t *used) {
    return NAME(decode64)(in, count, out, used, 0);
}

TARGET
static size_t NAME(sums64)(const uint8_t *in, size_t count, int64_t *out, size_t *used, int64_t *sum) {
    return NAME(decode64)(in, count, out, used, sum);
}

TARGET
static size_t NAME(low32)(const uint8_t *in, size_t count, int32_t *out, size_t *used) {
    const uint8_t *p = in, *end = in + count;
    int32_t *o = out;
    while ((size_t)(end - p) >= CHUNK) {
        uint64_t bits = NAME(continuations)(p);
#if !defined(WITH_SHUFFLE)
        if (!singles(bits)) break;
#endif
        const uint8_t *q = p, *last = p + (CHUNK - VECTOR);
        while (q <= last) {
            uint32_t ahead = (uint32_t)bits & 0xFFFF;
            if (ahead == 0) {
                NAME(lowBytes)(NAME(load)(q), o);
                o += VECTOR;
                q += VECTOR;
                bits >>= VECTOR;
                continue;
            }
#if defined(WITH_SHUFFLE)
            unsigned pattern = ahead & (PATTERNS - 1);
            const Step *step = &steps[pattern];
            if (step->kind != ALONE) {
                bytes16 lanes = NAME(shuffled)(NAME(load)(q), shuffles[pattern]);
                if (step->kind == QUADS) {
                    NAME(lowQuads)(lanes, o);
                } else {
                    NAME(lowPairs)(lanes, o);
                }
                o += step->values;
                q += step->taken;
                bits >>= step->taken;
                continue;
            }
#endif
            uint64_t raw;
            size_t length = alone(q, &raw);
            if (length == 0) {
                p = q;
                goto done;
            }
            *o++ = (int32_t)(uint32_t)raw;
            q += length;
            bits >>= length;
        }
        p = q;
    }
done:
    *used = (size_t)(p - in);
    return (size_t)(o - out);
}
