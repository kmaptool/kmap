# Where this style comes from

The style is transcribed from **openstreetmap-carto**, the stylesheet that draws
openstreetmap.org itself.

    https://github.com/openstreetmap-carto/openstreetmap-carto
    Licence: CC0 1.0 public domain dedication, and explicitly so for the look:
    "For avoidance of doubt, this includes the cartographic design."

CC0 means no conditions at all; the attribution here is courtesy and
traceability, not obligation. `LICENSE.md` beside this file quotes the
dedication in full.

Every colour, width, dash and pattern was read from one commit:

    1cc4b89c48e4385b607d63156d6f8f1eea8b35a2

from `style/landcover.mss`, `style/roads.mss`, `style/road-colors-generated.mss`
(generated from `road-colors.yaml`), `style/water.mss`, `style/admin.mss`,
`style/buildings.mss`, `style/power.mss`, `style/aerialways.mss`,
`style/ferry-routes.mss`, `style/amenity-points.mss`, `style/style.mss` and
`project.mml` (which tags a layer selects at all). Each line of `palette.txt` names
its file and line. Nothing is kmap's own invention.

## Codes and meanings

The type codes are kmap's, read out of the materialized rule set. Several codes
carry more than one kind of OSM object; each code is drawn as carto draws the
code's meaning, the one `Assets/styles/type-names.txt` gives it (from the owner's
reference TYP), and the OSM features kmap's rules put on it decide what it
looks like. So line 0x16 is a footway, 0x07 a service road (kmap's bridleways
land there too), 0x2b a cliff (via ferrata, aretes and ridges too), 0x30 a
sports track (raceways and gallops too; topoactive's label for it is "Track");
polygon 0x0c is industrial (construction and landfill too), 0x1c farmland
(topoactive labels it Grassland; kmap puts greenfield there too), 0x26 a
farmyard, 0x19 a pitch (sports centres, stadiums and recreation grounds too).
The catch-all areas 0x21 Tourism, 0x23 Amenity and 0x24 Structure take every
tourism=*, amenity=* and man_made=* area no earlier rule took; carto fills some
of those, each in its own colour, and the rest not at all, so they are clear.

## Reference zoom and pixels

Values are carto's at **z16**, where a z15 value holds when carto sets none for
z16. One carto pixel is one device pixel: a width is rounded half up, at least
1. A road's ink is carto's fill width (its line width less two casings),
rounded; its casing is 1 pixel either side, so the palette width is ink + 2.
Dash lengths are carto's z16 dasharray, rounded the same way; where carto's dash
depends on surface or tracktype, the unknown case is used (footway, path and
cycleway `int_surface = null`; track with no tracktype). Where carto's lines
have parts a TYP line cannot hold, the main stroke is kept: the country and
state borders keep their wide band without the thin dashed centre, the pipeline
keeps its line without the 3-pixel flanges, the aerialway its grey line without
the black ticks, the protected area the colour on its boundary, where carto's
inner band and outer line both lie, centred. A stream's white glow (0.3 px
either side at z16) rounds to nothing.

## Opacity

A TYP colour is opaque. A colour carto draws translucent is composited over
carto's land colour #f2efe9 and the result used, and the note says so. The one
exception is a pattern's ink, which is composited over the fill it lies on, as
carto draws it there (the wood's leaves, #6b8d5e at the layer's 0.4, over
@forest #add19e give #93b684; over land they would come out paler than the wood).
An image whose pixels carry their own varying alpha (scree, bare rock) takes its
colour at the median alpha of its inked pixels.

## Patterns

Dashes and patterns are the bitmaps in `graphics.txt`, drawn by a maintainer's
tool from carto's values above and from carto's own files in `symbols/` and
`patterns/` of the same commit, unchanged. A bitmap holds 2 colours: a pixel more
than half opaque takes the ink, the rest the area's fill. A fill pattern is drawn at
its own size within the 32 x 32 tile, a larger one cut to a window of it:

- a 256 or 512 tile is seen through a 32 x 32 window: one that cuts no symbol
  at its edge and holds some ink, with the share of ink closest to the whole
  tile's, the first in reading order on a tie (for rock, where no window is
  clean, the closest share alone);
- an 8 or 30 pixel tile is repeated over 32 x 32 (the 30 pixel garden pattern
  leaves a 2 pixel seam);
- an image drawn at an opacity of its own (vineyard .38, military and danger
  hatches .12) has that opacity lifted back out of its alpha, so its shape
  decides which pixels are ink; the opacity is in the ink colour already.

The tile then repeats every 32 pixels, so carto's scattered symbols (trees,
scrub) come out on a regular grid. A dash whose period does not divide 32 breaks
once at the seam of the 32-pixel line bitmap.

## Line widths are topoactive's

The widths are not carto's. A line takes the whole width kmap's topoactive gives
the same code, casing included: a path 2 pixels (topoactive's 1 left carto's salmon
too faint on a device), a track and a cycleway 2, a
service road 3, a roundabout 6 to 8, a river 2, a stream 1, a railway 3, a cliff
4. A line topoactive leaves to the device (the roads 0x01 to 0x06 and their
links, 0x0e path, 0x0f steps, 0x10, 0x31 to 0x35) has no entry in this style
either, so the device draws it at its own width, and a code kmap widened falls
back to the one it widened, as with topoactive (0x0e and 0x0f to 0x16). Colours
and dashes stay carto's; the original's width in a note is for the record. A
cased line narrower than 3 pixels has no room for a casing either side: its dash
gaps show the casing, or, undashed, it is drawn in its casing alone.

## Not drawn

What carto does not draw at all is a clear section in `graphics.txt`
(`poly <code> none`, `line <code> none`), so what lies beneath shows:

- polygons 0x02 Suburb, 0x03 Village (place areas, labelled only), 0x16 Nature
  Reserve (outlined only, by line 0x19), 0x1d Common, 0x1f Mountain meadow
  (natural=fell), 0x52 Bare Ground (kmap puts natural=tundra there), 0x21
  Tourism, 0x22 Historic, 0x23 Amenity, 0x24 Structure, 0x47 Waterfall;
- lines 0x12 Plateau rim (natural=fell) and 0x24 Valley.

0x3d Bay is not filled by carto either, but the sea under it is, so it takes the
water colour. 0x51 Wetland (natural=wetland with no type) has no fill in carto,
only its blue pattern, which is drawn over land. The military and danger
hatches are drawn without the faint fill under them, which is within a few
steps of land, so what lies beneath shows between the lines.

Night colours are not in the table: kmap derives them, for flat colours and
bitmaps alike.

## Icons

Every icon is drawn from a vector at 20 pixels with a soft edge: a partly covered pixel
is its ink blended over the land. CyclOSM ships the same file.

- carto's own symbol (`symbols/`, CC0, the commit above) for the code's meaning, in the
  `marker-fill` carto gives it in `style/amenity-points.mss`: gastronomy #C77400, amenity
  brown #734A08, health #BF0000, transport and accommodation #0092DA, shop #AC39AC,
  leisure #0D7813, landform #D08F55, air transport #8461C4, man-made #666666, water
  #4D80B3. Its barrier marks, a fraction of its 14 px grid, are scaled as the grid is.
- Where carto draws no symbol, a Maki (v8.0.0) or Temaki (v5.13.0) icon, CC0, in the
  carto ink of its category; the same icons opentopomap uses, each checked against
  topoactive's meaning for the code.
- A code topoactive marks with its plain label anchor (water and land names, the
  junction, Wi-Fi, geyser, military, cemetery, nature reserve, 0x661a) gets that anchor
  square, with its label. The rock 0x6614 is topoactive's own small ring.

Where a code holds several kinds of object, the symbol is the main meaning's: 0x2f08 the
bus station, 0x3003 the town hall, 0x2b02 the guest house, 0x2c0b the neutral place of
worship, every restaurant code the restaurant, 0x3200 the gate, 0x6613 the mountain pass
in transport blue, 0x2f09 the ferry terminal, 0x2c0d the artwork, 0x2c0c the peak in
red. Night lifts each ink towards white; an ink the grey night land would swallow keeps
its darkness. The counts are in the header of `points.txt`; each section names its
source and ink. The repair mark 0x660b is kmap's own and has no section here.
