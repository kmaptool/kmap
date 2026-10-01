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

// Builds the tables. Call it before anything else, from 1 thread.
void kmap_varints_prepare(void);

// Whether this machine has the instructions; without them the calls decode nothing.
int kmap_varints_vectored(void);

// Zigzag varints as signed 64-bit values.
size_t kmap_varints_zigzag64(const uint8_t *in, size_t count, int64_t *out, size_t *used);

// Varints kept as their low 32 bits.
size_t kmap_varints_low32(const uint8_t *in, size_t count, int32_t *out, size_t *used);

#endif
