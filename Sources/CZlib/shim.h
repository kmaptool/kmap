#ifndef KMAP_CZLIB_SHIM_H
#define KMAP_CZLIB_SHIM_H

// zlib's own header, reached through one of ours so the module map has a file
// inside the package to point at. Nothing is added: the whole of zlib.h is what
// Swift sees, and `compress2`/`uncompress`/`crc32` are the parts kmap uses.
#include <zlib.h>

#endif
