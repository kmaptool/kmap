#ifndef KMAP_VECTOR_TIER_H
#define KMAP_VECTOR_TIER_H

// How much vector code this build and this machine allow. The machine is asked while
// running, so 1 binary serves every processor of its architecture.
//
//   0  none: a big-endian build, one given KMAP_NO_VECTOR, or another architecture
//   1  NEON on ARM; on x86, SSE2, which every x86-64 has
//   2  SSSE3, which adds the byte shuffle by a table
//   3  SSE4.1, which adds widening a lane in 1 instruction
int kmap_vector_tier(void);

// For the tests: allows no tier above `most` from here on, and answers the tier that
// leaves. Not to be called while a decode is running.
int kmap_vector_limit(int most);

#endif
