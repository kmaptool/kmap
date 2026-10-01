#ifndef KMAP_VECTOR_SUPPORT_H
#define KMAP_VECTOR_SUPPORT_H

#include "vector_tier.h"

// Which vector instructions this build may use. NEON is part of every 64-bit ARM and
// SSE2 of every x86-64; SSSE3 and SSE4.1 are not, so the functions that use them are
// compiled for them by themselves and chosen by `kmap_vector_tier`.
//
// The loops read a vector's bytes as wider lanes lowest byte first, so a big-endian
// build gets none of them, and neither does one given KMAP_NO_VECTOR: the calls then
// do nothing and say so, and the caller takes its own byte-at-a-time path.

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define KMAP_NO_VECTOR 1
#endif

#if defined(KMAP_NO_VECTOR)
#elif defined(__aarch64__) || defined(_M_ARM64)
#define KMAP_NEON 1
#include <arm_neon.h>
#elif defined(__x86_64__) || defined(_M_X64)
#define KMAP_SSE 1
#include <immintrin.h>
#define KMAP_SSSE3 __attribute__((target("ssse3")))
#define KMAP_SSE41 __attribute__((target("sse4.1")))
#endif

enum { KMAP_TIER_NONE = 0, KMAP_TIER_BASE = 1, KMAP_TIER_SSSE3 = 2, KMAP_TIER_SSE41 = 3 };

#endif
