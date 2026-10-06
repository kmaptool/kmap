#include "vector_support.h"

#if defined(KMAP_SSE)

#if defined(_MSC_VER)
#include <intrin.h>
#else
#include <cpuid.h>
#endif

// Whether the system saves the 256-bit registers when it switches threads. Without
// that a processor with AVX2 still faults on it.
__attribute__((target("xsave")))
static int wideRegistersKept(void) {
    const unsigned long long xmm = 1u << 1, ymm = 1u << 2;
    return (_xgetbv(0) & (xmm | ymm)) == (xmm | ymm);
}

static int detect(void) {
    const unsigned ssse3 = 1u << 9, sse41 = 1u << 19, osxsave = 1u << 27, avx = 1u << 28;
    const unsigned avx2 = 1u << 5;
    unsigned features = 0, extended = 0;
#if defined(_MSC_VER)
    int info[4];
    __cpuid(info, 1);
    features = (unsigned)info[2];
    __cpuid(info, 0);
    if (info[0] >= 7) {
        __cpuidex(info, 7, 0);
        extended = (unsigned)info[1];
    }
#else
    unsigned a, b, c, d;
    if (__get_cpuid(1, &a, &b, &c, &d)) features = c;
    if (__get_cpuid_count(7, 0, &a, &b, &c, &d)) extended = b;
#endif
    if (!(features & ssse3)) return KMAP_TIER_BASE;
    if (!(features & sse41)) return KMAP_TIER_SSSE3;
    if ((features & (osxsave | avx)) == (osxsave | avx) && (extended & avx2) && wideRegistersKept())
        return KMAP_TIER_AVX2;
    return KMAP_TIER_SSE41;
}

#elif defined(KMAP_NEON)

static int detect(void) { return KMAP_TIER_BASE; }

#else

static int detect(void) { return KMAP_TIER_NONE; }

#endif

// Found on the first asking. Threads racing here find the same answer, so relaxed atomics
// (plain loads and stores) suffice without a lock.
static int found = -1;
static int most = KMAP_TIER_AVX2;

int kmap_vector_tier(void) {
    int tier = __atomic_load_n(&found, __ATOMIC_RELAXED);
    if (tier < 0) {
        tier = detect();
        __atomic_store_n(&found, tier, __ATOMIC_RELAXED);
    }
    int allowed = __atomic_load_n(&most, __ATOMIC_RELAXED);
    return tier < allowed ? tier : allowed;
}

int kmap_vector_limit(int limit) {
    __atomic_store_n(&most, limit < KMAP_TIER_NONE ? KMAP_TIER_NONE : limit, __ATOMIC_RELAXED);
    return kmap_vector_tier();
}
