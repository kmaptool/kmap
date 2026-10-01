# libdeflate 1.26

Deflate and inflate for every platform kmap builds on. kmap only ever compresses whole
blocks in memory, which is the 1 thing libdeflate does, and does fast.

The sources are here rather than asked of the system because no platform ships the
library by default, and because one copy means a tile comes out as the same bytes on
macOS, Linux, WSL and Windows.

Unmodified, from <https://github.com/ebiggers/libdeflate/releases/tag/v1.26>. `COPYING`
is the upstream licence (MIT) and stays with the code.

## What is here and what is not

The wrapped stream format (2-byte header, body, adler32 tail) and what it stands on:
the deflate compressor and decompressor, adler32, and the CPU detection for ARM and x86.

    lib/adler32.c  lib/deflate_compress.c  lib/deflate_decompress.c  lib/utils.c
    lib/zlib_compress.c  lib/zlib_decompress.c
    lib/arm/cpu_features.c  lib/x86/cpu_features.c

Not the gzip wrapper and not crc32, which only gzip uses: kmap writes and reads
wrapped streams, in PBF blobs and GeoTIFF tiles, and never a gzip file.

The layout is upstream's, so the sources include each other as they do there, with 1
difference: `libdeflate.h` sits in `include/`, which is the folder SwiftPM exports to
Swift and puts on the include path of the sources themselves.

The vector code is chosen while running: libdeflate asks the processor what it has
(cpuid on x86, the system on ARM) and falls back to plain C.

## Updating it

Copy the same files from a new release, keep the layout, and change nothing else.
A new version may pack a block into different bytes; the tests hold the digest of
1 stream, so they will say so.
