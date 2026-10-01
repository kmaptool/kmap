#ifndef KMAP_VECTOR_SUPPORT_H
#define KMAP_VECTOR_SUPPORT_H

// Which vector instructions this build may use. NEON is part of every 64-bit ARM;
// SSE4.1 is not part of every x86-64, so there each function is compiled for it
// by itself and the machine is asked before any of them runs.
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
#define KMAP_TARGET
#elif defined(__x86_64__) || defined(_M_X64)
#define KMAP_SSE 1
#include <immintrin.h>
#if defined(_MSC_VER)
#include <intrin.h>
#else
#include <cpuid.h>
#endif
#define KMAP_TARGET __attribute__((target("sse4.1")))

static inline int kmap_has_sse41(void) {
    const int sse41 = 19;
#if defined(_MSC_VER)
    int info[4];
    __cpuid(info, 1);
    return (info[2] >> sse41) & 1;
#else
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
    return (c >> sse41) & 1;
#endif
}
#endif

#endif
