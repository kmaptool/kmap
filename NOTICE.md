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
stb_image (public domain) and, on Windows only, zlib 1.3.1 (zlib licence). Each folder's
own README or PROVENANCE.md has the details.

mkgmap (GPL v2), pyhgtmap (GPL v2) and Java (Eclipse Temurin from Adoptium) are not
shipped: kmap downloads them onto the user's machine on request. kmap also patches mkgmap
from source on that machine; the patched jar is GPL v2, lives in `~/.kmap` and is never
redistributed. The tile splitter is kmap's own. Map data is OpenStreetMap (ODbL, via
Geofabrik) and so is everything built from it; coastline and boundary packs come from
thkukuk.de; elevation comes from Copernicus DEM, Viewfinder Panoramas, SRTM or ALOS, each
under its provider's own terms.
