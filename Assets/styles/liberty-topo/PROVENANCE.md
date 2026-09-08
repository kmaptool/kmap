# Where this style comes from

The palette is transcribed from **OSM Liberty Topo**, a topographic basemap
style built on OSM Liberty, which is itself built on Mapbox OSM Bright.

    https://github.com/nst-guide/osm-liberty-topo
    Style JSON: BSD-3-Clause, inherited from Mapbox OSM Bright — its text is
    kept here as LICENSE-osm-bright.txt.
    The look and feel: Creative Commons Attribution 3.0, from the same source.
    The data schema it styles is OpenMapTiles, whose design licence is
    CC-BY 4.0 and asks that products using the style credit OpenMapTiles.
    The project's own LICENSE.md is kept here verbatim.

Every map kmap builds with this style carries the credit those licences ask
for, beside the OpenStreetMap attribution.

What was taken is the colour of each thing, read out of `style.json`
(gh-pages) on 2026-09-08 and written against the type codes kmap's rules emit.
No code, no sprites, no raster layers: the aerial, FSTopo and hillshade
sources this style draws over cannot travel into a Garmin TYP at all.

It is a minimal look on purpose. The OpenMapTiles schema it reads knows nine
kinds of ground — wood, grass, ice, sand, park, residential, cemetery, hospital
and school — and everything else is left to the background. kmap's rules draw
far more than that, so every number this style does not paint takes the
background colour and disappears into the ground, which is exactly what the
original does with it. Those lines are marked `# ground` in the table, and they
are not kmap inventing a colour: they are kmap declining to.

Two things the style does define that kmap had never painted: the contour
lines, in its own browns, and the yellow casing it puts under trails.

The POI icons are the style's own: the Maki set it draws with (CC0), the `_15`
markers in `svgs/svgs_iconset`, rendered at 16 px with rsvg-convert on
2026-09-08 and read back three ways — the marker's ring and glyph are the ink,
its disc is white, the rest transparent. Night turns the marker over: a light
glyph on a dark disc. Seventy-one of kmap's point codes have one; where Maki
has no symbol for a thing kmap draws, the receiver keeps its own, as it does
for every code no palette paints.

Attribution, as the licences ask: © OSM Liberty Topo and OSM Liberty
contributors, BSD-3-Clause; look and feel after Mapbox OSM Bright, CC-BY 3.0;
schema and design © OpenMapTiles (https://openmaptiles.org/), CC-BY 4.0.
