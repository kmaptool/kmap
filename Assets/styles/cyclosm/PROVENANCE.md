# Where this style comes from

The style is transcribed from **CyclOSM**, the outdoor and cycling style for
OpenStreetMap, at one fixed commit:

    https://github.com/cyclosm/cyclosm-cartocss-style
    commit 0632363794f90f5d0b38ca22677a07b80a38b1af

Every colour, width, dash and pattern in `palette.txt` and `graphics.txt` is
read from CyclOSM's own files at that commit (`palette.mss`, `road-colors.mss`,
`roads.mss`, `base.mss`, `admin.mss`, `aerialways.mss`, `ferry-routes.mss`,
`power.mss`, `views.sql`, `project.mml`), and each entry names
its file and line. Nothing is invented and nothing is borrowed from a
neighbouring entry.

## The ground colours are CyclOSM's

Compared value for value with Hydda's `hyddafull/palette.mss` at commit
bb27f0a9cad1920e19ae8febd39f6f9328369e6f, the one CyclOSM's `LICENSE.md` links
(the repository is now karlwettin/carto-style-hydda), most ground colours do not
come from Hydda: `@land`, `@water`, `@grass`, `@wooded`, `@scrub` and
`@building` have other values in Hydda, and `@meadow`, `@heath`, `@farmland`,
`@glacier`, `@quarry`, `@sand` and `@bare_ground` are not in Hydda at all. They
are CyclOSM's own. What `palette.mss` shares with Hydda is `@park`, `@cemetery`,
`@hospital`, `@school`, `@sports`, `@parking` and the formulas of `@stadium`,
`@pitch`, `@track` and `@industrial`. CyclOSM's `LICENSE.md` still names Hydda
(Apache License 2.0) for the colours of `palette.mss` as a whole, so that
attribution stays.

## How the values were turned into a Garmin map

- **Meaning.** kmap's rules put more than one kind of object on some codes. The
  name of each code is the one `Assets/styles/type-names.txt` gives it, and the
  code is drawn as CyclOSM draws the OSM features kmap's rules put on it: line
  0x16 a path (footways and pedestrian streets too), 0x07 a service road, 0x2b
  a cliff, 0x30 a sports track (raceways and gallops too; topoactive labels it
  "Track"), polygon 0x0c industrial, 0x19 a sports ground, 0x1c farmland
  (topoactive labels it Grassland). The catch-all areas 0x21 Tourism, 0x23
  Amenity and 0x24 Structure take every tourism=*, amenity=* and man_made=* area
  no earlier rule took; CyclOSM fills a few of those, each in its own colour,
  and the rest not at all, so they are clear. The names in `palette.txt` are
  that file's English.
- **Zoom.** The reference is CyclOSM at z16: 1 CartoCSS pixel is 1 device
  pixel. Line widths are not CyclOSM's but topoactive's (below).
- **Opacity.** Where CyclOSM draws with opacity (admin boundaries, the
  protected-area band, the military edge, the cemetery and leaf patterns),
  the colour is composited over CyclOSM's land colour `@land #eee5dc`, or over
  the fill it lies on, and the note says so.
- **Not drawn.** What CyclOSM does not draw at all (place areas, farmyards,
  tourism, historic and amenity areas, salt ponds, natural=fell and its edge,
  cutlines, valleys, pipelines, bays and waterfall areas) is a clear section in
  `graphics.txt`, so what lies beneath shows, noted "not drawn by CyclOSM".
  Via ferrata, aretes and ridges share line 0x2b with cliffs and are drawn as
  cliffs.
- **Dashes.** CyclOSM dashes tracks, paths, footways and bridleways by surface.
  kmap's codes do not carry the surface, so every one takes the unknown-surface
  dash 10,1.
- **Military.** The danger hatch is drawn with its lines alone, without its
  faint tint, so what lies beneath shows between them.
- **Night.** CyclOSM has no night design. kmap derives the night colours, as
  for every shipped style, snapped to the steps a MIP watch screen can show.

## Line widths are topoactive's

The widths are not CyclOSM's. A line takes the whole width kmap's topoactive
gives the same code, casing included: a path 1 pixel, a track and a cycleway 2,
a service road 3, a roundabout 6 to 8, a river 2, a stream 1, a railway 3, a
cliff 4. A line topoactive leaves to the device (the roads 0x01 to 0x06 and
their links, 0x0e path, 0x0f steps, 0x10, 0x31 to 0x35) has no entry in this
style either, so the device draws it at its own width, and a code kmap widened
falls back to the one it widened, as with topoactive (0x0e and 0x0f to 0x16).
Colours and dashes stay CyclOSM's; the original's width in a note is for the
record. A cased line narrower than 3 pixels has no room for a casing either
side: its dash gaps show the casing, or, undashed, it is drawn in its casing
alone.

## The pattern images

The patterns in `graphics.txt` are drawn by a maintainer's tool from the images
CyclOSM draws them with, unchanged, from its own `symbols/openstreetmap-carto/` folder at the commit above.
They are openstreetmap-carto symbols, CC0 public domain (CyclOSM's `LICENSE.md`
says so); scree_overlay.png, rock_overlay.png, scrub.png, wetland.png,
quarry.svg and the leaftype_*.svg files are identical to openstreetmap-carto's
at commit 1cc4b89c48e4385b607d63156d6f8f1eea8b35a2, and cliff2.svg differs from
it, so CyclOSM's copy is the one kept. orchard.png, vineyard.png,
allotments.png, danger_red_hatch.png and grave_yard_generic_many.svg are not in
that carto commit and come from CyclOSM only.

    cliff2.svg                    cliff, z>=15 (base.mss:464-469)
    scree_overlay.png             scree, shingle (base.mss:71-75)
    rock_overlay.png              bare rock (base.mss:67-70)
    scrub.png                     scrub (base.mss:77-81)
    orchard.png                   orchard (base.mss:96-102)
    vineyard.png                  vineyard (base.mss:86-92)
    allotments.png                allotments (base.mss:103-109)
    wetland.png                   wetland (base.mss:57-61)
    quarry.svg                    quarry (base.mss:111-113)
    grave_yard_generic_many.svg   cemetery (base.mss:23-30)
    danger_red_hatch.png          military, danger area (base.mss:249-252)
    leaftype_unknown.svg          forest, woodland (base.mss:267-275)
    leaftype_needleleaved.svg     coniferous forest (base.mss:267-275)
    leaftype_broadleaved.svg      broadleaved forest (base.mss:267-275)

Each image is drawn at its own size and repeated within, or cut to, the 32 x 32
tile; a pixel more opaque than the cut (half, unless the note in `palette.txt`
says otherwise) is ink. The floors kmap lays under every wood and scrub, 0x59 and
0x5b, are flat, as topoactive's are.

The POI icons are openstreetmap-carto's symbols (CC0), the same set the carto
style here uses; CyclOSM draws POIs with those icons too, among others.

## Licences

Two licence files are kept here. `LICENSE.md` is CyclOSM's own, verbatim: it
names BSD-3-Clause for everything it does not list separately, Apache 2.0 for
the palette colours (as based on Hydda) and CC0 for the openstreetmap-carto
symbols, but carries none of the texts. `LICENSE-osm-bright.txt` is the
BSD-3-Clause text it points at, Mapbox's, for the style CyclOSM is based on, so
the conditions the licence asks to be retained travel with the values.

CyclOSM is itself based on Mapbox OSM Bright (BSD-3-Clause) and takes its
contour work from OpenTopoMap.

Attribution, as the licences ask: (c) CyclOSM contributors (BSD-3-Clause),
palette colours based on the Hydda style (Apache License 2.0), based on Mapbox
OSM Bright (BSD-3-Clause); pattern images from openstreetmap-carto (CC0).
