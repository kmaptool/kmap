# Where this style comes from

The palette is transcribed from **OSM Liberty Topo**, a topographic basemap
style built on OSM Liberty, which is itself built on Mapbox OSM Bright.

    https://github.com/nst-guide/osm-liberty-topo
    Style JSON: BSD-3-Clause, inherited from Mapbox OSM Bright. Its text is
    kept here as LICENSE-osm-bright.txt.
    The look and feel: Creative Commons Attribution 3.0, from the same source.
    The data schema it styles is OpenMapTiles, whose design licence is
    CC-BY 4.0 and asks that products using the style credit OpenMapTiles.
    The project's own LICENSE.md is kept here verbatim.

Every map kmap builds with this style carries the credit those licences ask
for, beside the OpenStreetMap attribution.

## What was read, and at which commit

    style.json   nst-guide/osm-liberty-topo, gh-pages,
                 commit fa884f95ea46af2af4bd65269f9a93a5edd63bd2
    sprite       sprites/osm-liberty-topo.json and .png, same commit
    schema       nst-guide/openmaptiles, commit 9c7ba7a3799df9166164bbc1d8bb294ed16668f5:
                 layers/*/*.yaml and mapping.yaml, which decide which OSM tags
                 reach which layer and class

Every colour, width, dash and pattern in `palette.txt` and `graphics.txt` is the
style's own, and the note beside it names the layer id it comes from. No value
is kmap's: where the style draws nothing, nothing is drawn.

## How a value was carried over

- **Which layer.** kmap's codes are not the style's classes. The meaning of a
  code is the one `Assets/styles/type-names.txt` gives it (the owner's
  reference TYP), and the code is drawn as the style draws that meaning: line
  0x07 (Service Road) as `road_service_track`, line 0x16 (Path) as the trail
  layers `road_path_pedestrian_trail`, polygon 0x19 (Sports Ground) as the
  style's pitches and stadiums, which it does not draw. The fork of the schema
  decides the class: there, a park, a garden, a golf course, allotments, scrub,
  heath and fell are all landcover `grass`, while a national park or a nature
  reserve is the `park` layer.
- **Zoom 16.** A width or an opacity that changes with zoom is taken at zoom
  16, by the style's own interpolation (its `base`), at 1 CSS pixel to 1
  device pixel. Line widths are not the style's but topoactive's (below).
- **Opacity.** A colour drawn with opacity is composited over the style's
  background, rgb(239,239,239), and the result is what the table carries. A
  wood is hsla(98,61%,72%,0.7) at fill-opacity 0.4, so 0.28 of that green; a
  grass fill is 0.3; the park fill 0.7; ice 0.8 at zoom 16; the aeroway fill
  0.7; contours 0.4.
- **Dashes.** A dash in style.json is measured in line widths; it is
  multiplied by the layer's width at zoom 16 and rounded. A TYP line repeats
  every 32 pixels, so a dash cycle that does not divide 32 is cut where the
  bitmap starts again.
- **Not drawn.** What the style does not draw is a clear section in
  graphics.txt, so what lies
  beneath shows, marked
  "not drawn by Liberty Topo". The style's ground is minimal on purpose: of
  the schema's landcover it paints wood, grass, ice and sand, of its landuse
  only cemetery, hospital and school (and residential, but only to zoom 8),
  and it draws no cliffs, ferries, aerial ways, power lines, barriers, military
  areas or boundaries below admin level 4.

## Line widths are topoactive's

The widths are not Liberty Topo's. A line takes the whole width kmap's
topoactive gives the same code, casing included: a path 1 pixel, a track and a
cycleway 2, a service road 3, a roundabout 6 to 8, a river 2, a stream 1, a
railway 3, a cliff 4 (where the style draws them). A line topoactive leaves to
the device (the roads 0x01 to 0x06 and their links, 0x0e path, 0x0f steps, 0x10,
0x31 to 0x35) has no entry in this style either, so the device draws it at its
own width, and a code kmap widened falls back to the one it widened, as with
topoactive (0x0e and 0x0f to 0x16). Colours and dashes stay Liberty Topo's; the
original's width in a note is for the record. A cased line narrower than 3
pixels has no room for a casing either side: its dash gaps show the casing, or,
undashed, it is drawn in its casing alone.

## The drawings

`graphics.txt` holds what a flat colour cannot draw, drawn by a maintainer's
tool from the style's values and images:

- The trails (0x16): white dashes over the trail casing,
  rgb(206,172,52), which shows in the gaps.
- Cycleway (0x11), the intermittent stream (0x26) and the state
  boundary (0x1d): the style's dashes, with clear gaps.
- The national park edge (0x19): the park fill's 1-pixel outline,
  rgba(95,208,100,1) at the fill's 0.7, in the gaps of `park_outline`'s dashes.
  Those dashes, rgb(228,241,215), are left clear: a 1-pixel line holds one
  colour and a clear one, and that colour is next to the ground on either side.
- The railway (0x14): the style's 2 rail layers at
  zoom 16 drawn into a 32-pixel repeat: the 1-pixel `road_major_rail` and a
  3-pixel tie of `road_major_rail_hatching`. It is drawn for kmap from those
  values, not taken from the sprite; the ties stand 32 pixels apart instead
  of the style's 29.
- The pedestrian area (0x25): the
  sprite's `pedestrian_polygon` image (64 x 64 at pixel ratio 1, at 0,0 in the
  1x sprite), cut to its top left 32 x 32 byte for byte. The image repeats
  every 4 pixels, so the cut tiles exactly as the whole does. Its opaque
  pixels, composited over the background, are the ink; the rest is clear, as
  the style lays the pattern over whatever lies below. It is the only fill
  pattern the style uses.

A TYP bitmap holds 2 colours, a clear one counted, so the pattern's faint
pixels (alpha 73 of 255) fall to clear with the rest.

## The icons

The POI icons are the style's own: the Maki set it draws with (CC0), the `_15`
markers in `svgs/svgs_iconset` of the commit above. The style draws a point as
`{class}_11`, the class being the one the schema's `layers/poi/poi.yaml` files
the OSM tag under, so a code takes the marker of the class its meaning falls in
(the meaning `type-names.txt` gives it): a viewpoint is an `attraction`, a
department store `grocery`, a food court `fast_food`, a garden centre or any
other shop `shop`, a pitch `pitch`. Each is rendered at 16 px with rsvg-convert
and read back 3 ways: a pixel under alpha 112 is clear; of the rest, R+G+B under
600 is ink #333333 (the ring, a square badge, a coloured glyph), the rest white
(the disc, a white glyph). That rule gives back every icon rendered on
2026-09-08 and 2026-09-10 pixel for pixel. Night turns the marker over: a light
glyph on a dark disc.

Every point code kmap's rules emit has a section, but the settlement points
0x0100 to 0x0d00, whose dot and name the device draws: a code with no section is
not left blank, the device draws its own built-in icon for that number, often
one with another meaning. 99 of the 133 have the style's icon: every restaurant
code 0x2a00 to 0x2a12 (fast food 0x2a07 and the cafe 0x2a0e aside) the
restaurant whatever its cuisine, the tourist site 0x2c0d an `attraction`, the
nursing home 0x2f14 a `hospital`, the school 0x2c05 `school`, the park 0x2c06,
the zoo 0x2c07, the volcano 0x2c0c, skiing 0x2d06, the lift station 0x2f1b
`aerialway`, the cemetery 0x6403, and the mountain pass 0x6613 the `viewpoint`
the style draws a saddle with. The town hall and the fire station are the set's
own though the style cannot show them: it asks for `town_hall_11` and
`fire_station_11` where its sprite holds `town-hall_11` and `fire-station_11`.
The set's own icon for a meaning the schema does not keep is used too: the
lighthouse, the heliport, the amusement park for the theme park 0x2c01, the
wetland 0x6513, the telephone for the emergency phone 0x2f16, the shelter (the
schema's class for basic huts) for the wilderness hut 0x2b07, and the car the
style draws every car place with for the car wash 0x2f0e and car rental 0x2f02,
and the roadblock for the barriers 0x3200 to 0x3202 and the border crossing
0x3006, barrier=* points the schema imports but the style has no icon for.

The other 34 get the plain anchor square of the reference TYP, topoactive's
0x661a, copied byte for byte, day and night, with its label; it can be edited in
kmap's type editor. Never an icon of another meaning. Each says so in its
comment: the casino, bowling, ice rink, sports centre, Wi-Fi, charging station,
mast, tower, well, waterfall, geyser, bench, cliff, rock, cave, ford, wine
cellar, rock climbing, junction, services, military area, the water and land
names (bay, canal, glacier, island, lake, reservoir, stream, water, beach, cape,
nature reserve, a wood's name), and 0x661a, the anchor itself in topoactive. The
repair mark 0x660b is kmap's own, added by the build, and has no section here.

The night colours are kmap's, as for every shipped style, derived from the day
ones and snapped to the steps a MIP watch screen can show.

Attribution, as the licences ask: © OSM Liberty Topo and OSM Liberty
contributors, BSD-3-Clause; look and feel after Mapbox OSM Bright, CC-BY 3.0;
schema and design © OpenMapTiles (https://openmaptiles.org/), CC-BY 4.0.
