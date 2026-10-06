#ifndef KMAP_CONTOUR_CELLS_H
#define KMAP_CONTOUR_CELLS_H

#include <stddef.h>
#include <stdint.h>

// Marks as bit c of `marks` (word c / 64) the cell between columns c and c + 1 of rows `top`
// and `bottom` (`cells + 1` samples each) when its 4 corners are above `floor` and not all in
// 1 band. `band_top` and `band_bottom` give each sample's band: the levels below it. `marks`
// holds (cells + 63) / 64 words.
void kmap_contour_cells(const int16_t *top, const int16_t *bottom, const int32_t *band_top,
                        const int32_t *band_bottom, size_t cells, int16_t floor, uint64_t *marks);

#endif
