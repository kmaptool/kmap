# The style catalogue

One folder per shipped style. A style that ships lives INSIDE the binary
(`make assets` embeds it); nothing is unpacked into the user's folders. During
a build the TYP text is written into that build's own scratch directory and
dies with it. In the interface a shipped style cannot be edited or deleted —
only cloned into the user's library (`~/.kmap/typ/`), where the clone is
theirs. The same rule as zoom plans, for the same reason: what ships must be
impossible to lose.

Each folder carries its own PROVENANCE.md: where every colour and icon came
from, under what licence, and how it was taken. A style whose licence is not
kmap's stays under its own licence, marked in its folder.

A style whose licence asks to be credited says so in one line, and that line is
written into every map built with it, beside the OSM attribution.

Residents:
  osm-carto/     the look of openstreetmap.org  (openstreetmap-carto, CC0)
  opentopomap/   the OpenTopoMap look           (der-stefan/OpenTopoMap, CC-BY-SA)
  cyclosm/       an outdoor palette             (CyclOSM, BSD-3-Clause; ground
                 colours from Hydda, Apache 2.0 — its LICENSE.md is kept in the
                 folder beside PROVENANCE.md)
  liberty-topo/  a minimal topographic look     (nst-guide/osm-liberty-topo, BSD
                 and CC-BY 3.0; schema © OpenMapTiles, CC-BY 4.0; Maki icons,
                 CC0 — its licences are kept in the folder)
  kmap/          kmap's own look, one day
