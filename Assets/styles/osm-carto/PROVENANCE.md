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
the same code, casing included: a path 1 pixel, a track and a cycleway 2, a
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

`points.txt` holds openstreetmap-carto's own symbols (`symbols/` in the
repository, CC0, the commit above), one per code: the symbol carto draws for the
code's meaning, the one `type-names.txt` gives it. CyclOSM ships the same file.
Each SVG is rendered at 16 px with rsvg-convert, and a pixel whose alpha is 96
or more is ink (the lighthouse at more than 127). The ink is the
`marker-fill` carto gives that symbol in `style/amenity-points.mss`: gastronomy
#C77400, amenity brown #734A08, health #BF0000, transportation and accommodation
#0092DA, shop #AC39AC, religion #000000, landform #D08F55, air transport
#8461C4, leisure green #0D7813, man-made #666666, spring #7ABCEC, water text
#4D80B3. The bus station keeps its SVG's own blue and white, the cliff its line
tile's grey #999999. Night ink is the day ink lifted towards white and snapped
to the 0/85/170/255 steps a MIP display can show. Each section's comment names
its SVG and its ink.

Where a code holds several kinds of object, the symbol is the one for its main
meaning: 0x2f08 Station is carto's bus station (topoactive draws a bus there
too), 0x3003 the town hall, 0x2b02 the guest house, 0x2d01 the theatre, 0x2f10
the hairdresser, every restaurant code 0x2a00 to 0x2a13 (fast food 0x2a07 and the
cafe 0x2a0e aside) the restaurant whatever its cuisine (carto draws a food court
so too), 0x3200 the gate (gates, stiles, kissing gates and cycle barriers land
there), 0x6608 the generic tower, 0x6619 the cave entrance, 0x6613 the mountain
pass in transport blue (a saddle takes it in landform brown). Where the main
meaning has no symbol, another object on the code that fits it does: 0x2f09
Marina is carto's ferry terminal (marinas carry none), 0x2c0d Tourist site
its artwork (attractions carry none; an artwork is a sight, and kmap puts
artworks there). 0x2c0c Volcano is carto's peak in red, 0x2f02 the car rental,
0x2f1b the aerialway station's square in station colour, 0x6514 the ford. The
gates and the aerialway square are not 14 px symbols and are drawn at the same
16/14 scale as the rest; the peak, saddle and volcano, 8 px, at 16 px.

Every point code kmap's rules emit has a section, but the settlement points
0x0100 to 0x0d00, whose dot and name the device draws: a code with no section is
not left blank, the device draws its own built-in icon for that number, often
one with another meaning. A code for which carto draws no symbol fitting any
object on it gets the plain anchor square of the reference TYP, topoactive's
0x661a, copied byte for byte, day and night, with its label; it can be edited in
kmap's type editor. Never a symbol of another meaning: no fishing on a stadium,
no butcher on every shop. 36 codes: 0x2c08 sports ground and 0x2d0a sports
centre (carto names pitches, stadiums and sports centres but marks none), 0x2e04
mall, 0x2e0c shop and 0x3202 bollard (a plain dot in carto), 0x2f12 Wi-Fi, 0x6414
well, 0x6509 geyser, 0x6614 rock and stone, 0x6618 a wood's name, 0x661a (the
anchor itself in topoactive), and the codes carto only labels or leaves out:
0x2000, 0x230f, 0x2c01, 0x2c05, 0x2c06, 0x2c07, 0x2c0a, 0x2c0e, 0x2d06, 0x2d08,
0x3006, 0x6403, 0x640b, 0x6503, 0x6505, 0x650a, 0x650c, 0x650d, 0x650f, 0x6512,
0x6513, 0x6603, 0x6604, 0x6606, 0x6612. The repair mark 0x660b is kmap's own, added by the build, and has no section here.
