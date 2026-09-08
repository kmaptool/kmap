# zlib 1.3.1, for Windows only

The Unixes all have a zlib. macOS ships one in the SDK and every Linux
distribution packages it as `libz-dev`, so `Sources/CZlib` asks the system for
the copy the rest of the machine is already using, and that is what
`Package.swift` builds everywhere except here.

Windows has none, and there is nowhere to send somebody for one. kmap is meant to
arrive there as an installer and an .exe — a person who wants a Garmin map should
not first be asked to set up vcpkg — so on Windows the manifest builds this
directory instead, under the same module name, and `Sources/kmap/Core/Codec/Zlib.swift`
does not know the difference.

Unmodified, from <https://github.com/madler/zlib/releases/tag/v1.3.1>. `LICENSE-zlib`
is the upstream licence and stays with the code.

## What is here and what is not

Deflate and inflate, and the two checksums they need. Not the `gz*` half: kmap
compresses whole blocks in memory — `compress2`, `uncompress`, `crc32` — and never
opens a gzip file, so `gzread.c` and its neighbours would be code with no caller.

    adler32.c compress.c crc32.c deflate.c inffast.c
    inflate.c inftrees.c trees.c uncompr.c zutil.c

`gzguts.h` is here despite that: `zutil.c` includes it for the error-message table,
and it is a header with no sources behind it. Building with `Z_SOLO` would drop the
include and the gz layer together — and `compress`/`uncompress` with them, which are
the two functions kmap actually calls.

`include/` holds the two public headers, which is what SwiftPM exports to Swift;
the rest are zlib's own internals and sit next to the sources that include them.

## Updating it

Copy those ten sources and their headers from a new release, keep the layout, and
change nothing else. If a version ever has to differ from the system one on the
Unixes, that is a reason to look again at the split — not a reason to patch what
is here.
