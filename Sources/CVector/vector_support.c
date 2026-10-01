#include "vector_support.h"

#if defined(KMAP_SSE)

#if defined(_MSC_VER)
#include <intrin.h>
#else
#include <cpuid.h>
#endif

static int detect(void) {
    const unsigned ssse3 = 1u << 9, sse41 = 1u << 19;
    unsigned features = 0;
#if defined(_MSC_VER)
    int info[4];
    __cpuid(info, 1);
    features = (unsigned)info[2];
#else
    unsigned a, b, c, d;
    if (__get_cpuid(1, &a, &b, &c, &d)) features = c;
#endif
    if (!(features & ssse3)) return KMAP_TIER_BASE;
    return features & sse41 ? KMAP_TIER_SSE41 : KMAP_TIER_SSSE3;
}

#elif defined(KMAP_NEON)

static int detect(void) { return KMAP_TIER_BASE; }

#else

static int detect(void) { return KMAP_TIER_NONE; }

#endif

// Found on the first asking. Threads asking at the same moment all find the same
// answer, so nothing guards it.
static volatile int found = -1;
static volatile int most = KMAP_TIER_SSE41;

int kmap_vector_tier(void) {
    int tier = found;
    if (tier < 0) {
        tier = detect();
        found = tier;
    }
    int allowed = most;
    return tier < allowed ? tier : allowed;
}

int kmap_vector_limit(int limit) {
    most = limit < KMAP_TIER_NONE ? KMAP_TIER_NONE : limit;
    return kmap_vector_tier();
}
