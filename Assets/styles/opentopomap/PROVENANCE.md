# OpenTopoMap style: provenance

The style draws kmap's type codes the way OpenTopoMap's own Garmin style draws the same
meanings. Every colour, width, dash, pattern and draw order comes from their files in
<https://github.com/der-stefan/OpenTopoMap>, `garmin/style/` at commit
`60c50cb8329d67c8556cd9f25b4a8e50bfc19c91`:

- `typ/opentopomap.txt`, their TYP: colours, widths, bitmaps, `[_drawOrder]`;
- `typ/contours.txt`, their contour TYP;
- `opentopomap/lines`, `opentopomap/polygons` and `opentopomap/inc/*`, their rules: which
  OSM tags they draw, and on which of their numbers.

OpenTopoMap is (c) OpenTopoMap; the attribution rides in each file's header and in the
style's summary in the interface. On the licence question (CC-BY-SA in the repository's
`LICENCE`, CC-BY-NC-SA for the Garmin maps in its README) read `LICENSE.md` beside this
file before selling anything built with this style.

## Meaning, not number

Which OSM objects land on a code is decided by kmap's rules, and the name of each code is
the one `Assets/styles/type-names.txt` gives it. A code is drawn with their drawing for
the OSM objects kmap's rules put on it, moved to kmap's number where theirs differs: their
conifer forest 0x38 on kmap's 0x57, their sand 0x55 on 0x53, their footway 0x16 on kmap's
path 0x0e as well and on the sports track 0x30 (leisure=track is a footway to them;
topoactive labels 0x30 "Track"), their steps 0x13 on 0x0f, their fence 0x33 on kmap's
barrier 0x17, their slope 0x31 on kmap's cliff 0x2b, their meadow 0x17 on park, garden
and grassland 0x55, their vineyard 0x4e on 0x1b. kmap's 0x1c is farmland, for which they
have no rule. The floors kmap lays under every wood and scrub, 0x59 and 0x5b, are flat as
topoactive's: their forest's ground, and clear for their scrub, which has none. A
borrowed section takes the English and Russian of `type-names.txt` in place of their own
labels. Palette names are the English of `type-names.txt`.

Where their rules emit nothing for a meaning, or emit a polygon number their TYP neither
draws nor lists in its draw order, their map shows nothing there: the polygon is drawn
clear, and a line is drawn by nothing. A line number their rules emit without a section,
their pipeline 0x28, is drawn by the device's own default, as on their map. Each such
entry says which.

## Files

- `palette.txt`: flat colours and widths, each with its source as `file:line`. A road's
  width is their `LineWidth` plus a 1-pixel border either side. Draw order is their
  `[_drawOrder]`: their background (level 0) is level 1 here, their levels 1-6 are 3-8,
  and level 2 holds kmap's land and every polygon their map does not draw, which their
  order does not list and `graphics.txt` draws clear.

- `graphics.txt`: the bitmaps, written by a maintainer's tool; a section there replaces
  the flat colour the palette would give its code. It holds their sections and adds the
  clear lines and areas. Their `[_polygon]` and `[_line]` sections are copied whole. Only the
  `Type` line differs where kmap's number is not theirs, and a note after it names their
  number and the lines it was copied from. Their motorway is here because its 2-pixel
  border cannot be written as a palette row.

- `points.txt`: their `[_point]` icon sections, copied whole, for 48 of the point codes
  kmap's rules emit, each on the code whose meaning their rules draw with it. 37 sit on
  their own number, their labels included. 11 sit on another number of kmap's, with only
  the `Type` line changed, their labels left out and a note naming their number: their
  campsite on 0x2b03, their hut on the lean-to 0x2b05 (tourism=lean_to is a hut to
  them), their monument on the memorial 0x2c12, their telephone on the emergency phone
  0x2f16 and the telephone 0x2f18, their bus stop on the taxi 0x2f19 (their rules put
  taxis there), their drinking water on 0x5000, their mast on 0x6411, their plain tower
  on 0x6608, their barrier on 0x3200 and 0x3202. kmap's 0x2f12 Wi-Fi keeps their
  telephone, as their rules put internet access on it. A meaning their TYP draws nothing
  for takes openstreetmap-carto's symbol (CC0), the section the carto style ships, day
  and night, each saying so in its own comment: 51 codes, among them fuel with a shop
  0x2e06 (fuel to them), the post box 0x2f15 (their 0x2f15 is recycling), the lift
  gate 0x3201 (their barriers leave it out), the marina 0x2f09 (carto's ferry terminal,
  which lands there too), the tourist site 0x2c0d (carto's artwork), the volcano
  0x2c0c, the car rental 0x2f02, the lift station 0x2f1b, the ford 0x6514 and the
  mountain pass 0x6613. Where neither draws the meaning, the code gets the plain anchor
  square of the reference TYP, topoactive's 0x661a, copied byte for byte, day only like
  their own, with its label, so no device icon of another meaning shows; it can be
  edited in kmap's type editor. 34 codes: 0x2c08, 0x2d0a, 0x2e04, 0x2e0c, the well
  0x6414, 0x6509, 0x6614, the wood's name 0x6618 (their tree is a single landmark tree),
  0x661a (the anchor itself in topoactive), and the codes neither draws: 0x2000, 0x230f,
  0x2c01, 0x2c05, 0x2c06, 0x2c07, 0x2c0a, 0x2c0e, 0x2d06, 0x2d08, 0x3006, 0x6403, 0x640b,
  0x6503, 0x6505, 0x650a, 0x650c, 0x650d, 0x650f, 0x6512, 0x6513, 0x6603, 0x6604, 0x6606,
  0x6612. Every point code kmap's rules emit has a section, 133, but the settlement
  points 0x0100 to 0x0d00, whose dot and name the device draws, and the repair mark
  0x660b, which the build adds.

Their TYP is day only. Night colours are kmap's, derived from the day colour, for the flat
sections, the clear ones and their copied sections alike; their day pixels and
colours are left as they are.

## Left out

- Their rail drawing on line 0x2d: kmap uses 0x2d for the edge of a military area, which
  they do not draw as a line. Their rail tunnels 0x2c and 0x2e and their forest edge
  0x11002 are left out too: kmap's rules emit none of them.

- The repair link kmap puts in across a kerb or a bank, line 0x0d, which no map style
  has. The build adds its own red dashes.
