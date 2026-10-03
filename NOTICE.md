# Notice

kmap's own code is MIT (see `LICENSE`). Two kinds of things in this repository are not:
`Assets/hideable.txt`, `Assets/mkgmap/redirects.txt` and `Assets/mkgmap/contour_lines`
quote rule lines from mkgmap's default style and are GPL v2, because a substitution has to
name the line it replaces exactly; and the built-in styles in `Assets/styles/` carry their
sources' terms — `osm-carto` from openstreetmap-carto (CC0), `opentopomap` from
OpenTopoMap's TYP source (CC-BY-SA per that project's own LICENCE file, though its README
calls the Garmin maps CC-BY-NC-SA — `Assets/styles/opentopomap/LICENSE.md` quotes both and
says which reading kmap ships on), `cyclosm` from CyclOSM (BSD-3-Clause,
its ground colours from the Hydda style under Apache 2.0) and `liberty-topo`
from OSM Liberty Topo (BSD, look and feel CC-BY 3.0, schema © OpenMapTiles
CC-BY 4.0, Maki icons CC0). Each style folder carries a
LICENSE.md — upstream's own where the project publishes one, otherwise one that quotes what
it does say — beside a PROVENANCE.md recording what was taken and what was changed. The
attribution also rides in each file's header and — where the licence asks to be credited —
in every map built with that style. Vendored code:
stb_image (public domain) and libdeflate 1.26 (MIT). Each folder's
own README or PROVENANCE.md has the details.

mkgmap (GPL v2), pyhgtmap (GPL v2) and Java (Eclipse Temurin from Adoptium) are not
shipped: kmap downloads them onto the user's machine on request. kmap also patches mkgmap
from source on that machine; the patched jar is GPL v2, lives in `~/.kmap` and is never
redistributed. The Java of those edits, in `Sources/kmap/Toolchain/MkgmapPatch.swift`,
quotes mkgmap's source and carries parts of it over, so it is GPL as mkgmap is (version 2,
and version 3 or later where the file it edits says so), not MIT. The tile splitter is kmap's own. Map data is OpenStreetMap (ODbL, via
Geofabrik) and so is everything built from it; coastline and boundary packs come from
thkukuk.de; elevation comes from Copernicus DEM (Copernicus DEM licence), FABDEM (CC BY-NC-SA 4.0,
non-commercial), GEDTM30 (CC BY 4.0), Viewfinder Panoramas, SRTM or ALOS, each under its
provider's own terms. kmap downloads them on the user's machine and ships none of them.

## libdeflate

Deflate and inflate are libdeflate 1.26, compiled into the binary, under its own licence:

```
Copyright 2016 Eric Biggers
Copyright 2024 Google LLC

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
