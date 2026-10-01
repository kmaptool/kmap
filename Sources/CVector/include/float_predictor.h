#ifndef KMAP_FLOAT_PREDICTOR_H
#define KMAP_FLOAT_PREDICTOR_H

#include <stddef.h>
#include <stdint.h>

// TIFF's floating-point predictor undone for a tile of 32-bit samples.
//
// Each row of `raw` is 4 planes of `width` bytes, most significant first, differenced
// as 1 run. The running sum is put back in place and `out` receives `rows * width`
// samples. Answers 0, having done nothing, where this machine lacks the instructions.
int kmap_float_rows(uint8_t *raw, size_t width, size_t rows, float *out);

#endif
