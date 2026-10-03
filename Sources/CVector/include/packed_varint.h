#ifndef KMAP_PACKED_VARINT_H
#define KMAP_PACKED_VARINT_H

#include <stddef.h>
#include <stdint.h>

// Packed protobuf varints, several at a time.
//
// Each call decodes from `in` while 64 bytes can still be read and no varint runs
// past 10 bytes, and answers how many values it wrote; `used` is how many bytes
// they took. The caller decodes what is left. `out` needs room for 16 values more
// than have been written, which a buffer of 1 value a byte of input always has.

// Which instructions do the work is `kmap_vector_tier`'s to say; at tier 0 the calls
// decode nothing.

// Builds the tables. Call it before anything else, from 1 thread.
void kmap_varints_prepare(void);

// Zigzag varints as signed 64-bit values.
size_t kmap_varints_zigzag64(const uint8_t *in, size_t count, int64_t *out, size_t *used);

// The same, each value added to `*sum` and the running total written in its place:
// delta-coded ids and coordinates. Wrapping, as the Swift caller's own sums are.
size_t kmap_varints_zigzag64_sums(const uint8_t *in, size_t count, int64_t *out, size_t *used, int64_t *sum);

// Varints kept as their low 32 bits.
size_t kmap_varints_low32(const uint8_t *in, size_t count, int32_t *out, size_t *used);

#endif
