#ifndef KMAP_ELEVATION_ROWS_H
#define KMAP_ELEVATION_ROWS_H

#include <stddef.h>
#include <stdint.h>

// Rows of little-endian 32-bit words to floats. With `differenced`, each word is the
// difference from its left neighbour (TIFF predictor 2, taken as integers whatever the
// sample format) and the running sum is what is read. `out` receives `rows * width`
// samples; `raw` is not changed. Answers 0, having done nothing, at tier 0.
int kmap_word_rows(const uint8_t *raw, size_t width, size_t rows, int differenced, float *out);

// Heights as big-endian 16-bit integers: held to -32768...32767, then rounded half away
// from zero. A height that is not finite, or equals `nodata` where `has_nodata`, is
// stored as 0. Answers how many were stored otherwise, or -1, having done nothing, at
// tier 0.
int64_t kmap_heights_f64(const double *in, size_t count, uint8_t *out);
int64_t kmap_heights_f32(const float *in, size_t count, float nodata, int has_nodata, uint8_t *out);

#endif
