# Where this style comes from

The palette is transcribed from **CyclOSM**, the outdoor and cycling style for
OpenStreetMap.

    https://github.com/cyclosm/cyclosm-cartocss-style
    Ground colours: `palette.mss`, whose values come from the Hydda style and
    are licensed under the Apache License 2.0.
    Roads and everything else: `road-colors.mss` and the rest of the style,
    BSD-3-Clause, as CyclOSM's own `LICENSE.md` states for anything it does not
    list separately. That file is kept here beside this one.

CyclOSM is itself based on Mapbox OSM Bright (BSD-3-Clause) and takes its
contour work from OpenTopoMap.

What was taken is the colour of each thing, read out of those two files on
2026-09-08 and written against the type codes kmap's rules emit. Nothing else
travelled: no icons, no code, no patterns. Where CyclOSM draws something with a
pattern rather than a flat colour — scree, orchards, wetland — or does not draw
it at all, the table says `# filled, not theirs` and uses the nearest neighbour
already in it. Where CyclOSM computes a colour from another (`@land * 1.05` for
residential ground), the table says `# worked out` and carries the result.

The POI icons are openstreetmap-carto's symbols (CC0), the same set the carto
style here uses — CyclOSM draws POIs with those icons too, among others.

Two licence files are kept here. `LICENSE.md` is CyclOSM's own, verbatim: it
names BSD-3-Clause for everything it does not list separately and Apache 2.0 for
the palette colours, but carries neither text. `LICENSE-osm-bright.txt` is the
BSD-3-Clause text it points at — Mapbox's, for the style CyclOSM is based on —
so the conditions the licence asks to be retained travel with the colours.

A protected area is drawn under the vegetation, not over it: a forest inside a
reserve is a forest, and the wash shows on the open ground around it.

A colour their palette defines but never draws with is not a colour of theirs.
`@nature_reserve` is one: nothing in the style uses it, and a protected area is
a wash of darkened `@wooded` at 15% over the ground with the boundary band in
`@wooded` — so that is what the table carries, and the unused green is left
where it was found. `@military` is a line colour too: the edge is drawn, the
field is not.

The day colours are the ones the style defines; the night ones are kmap's, as
for every shipped style, snapped to the steps a MIP watch screen can show.

Attribution, as the licences ask: © CyclOSM contributors (BSD-3-Clause), colours
from the Hydda style (Apache License 2.0), based on Mapbox OSM Bright
(BSD-3-Clause).
