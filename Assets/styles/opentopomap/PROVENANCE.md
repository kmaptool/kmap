# OpenTopoMap style — provenance

Three files carry the OpenTopoMap look on the type codes kmap's rules emit. All
of it comes from OpenTopoMap's own Garmin TYP source —
`garmin/style/typ/opentopomap.txt` in <https://github.com/der-stefan/OpenTopoMap>,
fetched 2026-08-31 (colours) and 2026-09-04 (icons and patterns).
OpenTopoMap is © OpenTopoMap; the attribution rides in each file's header and
in the style's summary in the interface.

On the licence: the repository's own `LICENCE` file says `CC-BY-SA` and names
no version, while its README says the Garmin maps are CC-BY-NC-SA. Which of
the two governs this TYP source is not settled inside the repository, and
`LICENSE.md` beside this file quotes both and says which reading kmap ships
on. Read it before selling anything built with this style.

- `palette.txt` — the colours, read for every code whose meaning both maps
  share. The chain: kmap rule → OSM tag → OpenTopoMap rule
  (garmin/style/opentopomap, includes too) → its TYP colour. 48 of 88 codes
  chained; the rest are filled in the palette's spirit, each marked
  `# filled, not theirs` in the table. The table is a measurement, and the flat
  sections kmap compiles from it are kmap's own text.

- `points.txt` — their `[_point]` icon sections, VERBATIM, for 45 of the 143
  point codes kmap's rules emit. Three of them sit on a number of kmap's, marked
  where they do: a tower, a barrier and the name of a wood. Their file draws
  nothing for the rest, so those carry openstreetmap-carto's symbols (CC0) — the
  set the carto style here already ships and the one CyclOSM borrows too. Each
  such section says so in its own comment. Without them a third of what the map
  knows would go unmarked.

- `graphics.txt` — their `[_polygon]` and `[_line]` pattern sections, VERBATIM.
  A section replaces the flat colour the palette would generate for its code.
  Some sit on a number of kmap's rather than their own, each saying so: the two
  forest kinds on the leaf-type codes, their meadow on a garden, a village green,
  common land and grassland, their mixed forest on woodland, their sand on a
  beach, their vineyard on kmap's vineyard as well as its orchard, their footway
  on kmap's path, their steps, fence, ferry, slope and forest edge on the numbers
  kmap draws those with. The drawing is theirs; only the number changed.

Two places where kmap draws what they leave out, and says so in the table:

- A **nature reserve**. Their rule for it is commented out and their TYP has no
  section for it, so the ground shows through here too — the reserve is the
  ground colour, and it is drawn below the vegetation rather than over it, so a
  forest inside a reserve is a forest. What marks it is the edge band, in their
  own forest-edge green.

- The **repair link** kmap puts in across a kerb or a bank, which no map style
  has. It is left out of the table on purpose: the build adds its own red dashes.
