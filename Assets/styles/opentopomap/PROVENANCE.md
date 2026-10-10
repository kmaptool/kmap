# Where this style comes from

OpenTopoMap's web (Mapnik) style, the one that draws opentopomap.org:

    https://github.com/der-stefan/OpenTopoMap, folder mapnik/, commit
    60c50cb8329d67c8556cd9f25b4a8e50bfc19c91
    CC-BY-SA, (c) OpenTopoMap (see LICENSE.md)

Colours, dashes and patterns are theirs, read at z16; each row of `palette.txt` names its
file and lines. kmap's codes are drawn as they draw the OSM objects kmap's rules put on each
code, and named after `Assets/styles/type-names.txt`.

## What kmap changed

- Line widths are topoactive's (kmap's reference TYP), but the path is 2 pixels: 1 left its
  dots too faint on a device. Lines topoactive leaves to the device have no row. Translucent colours are composited over their land #e0e0e0; the nature reserve band
  keeps its #85c243 without the 0.5 opacity, which left it too faint on a device.
- Draw order follows their layers, except: the built-up tint goes under the woods; park,
  pitch, quarry, cemetery, bare rock and scree go over them, as topoactive draws them; sand
  goes under the woods; the wood and scrub floors kmap adds sit a level under their
  patterns. A build lays the woods over the open cover.
- What they do not draw is clear and unlabelled; the valley line is clear but keeps its
  name, which they write.
- Their generic forest tile mixes 2 kinds of tree no 32 x 32 window holds: 1 broadleaf and
  1 conifer are moved onto the tile at their own size.
- Their hillshade is left out: the device shades its own relief.
- Night colours are kmap's, derived from the day ones.

## Icons

Every icon is drawn from a vector at 20 pixels with a soft edge. Their own symbols are pixel
art too small to enlarge, so for those meanings the openstreetmap-carto vector (CC0) is drawn
in their colour (black; water #1200FF; parking and transport #0024FF; health #DF091D; bus
#18A736); their saddle and viewpoint SVGs are used as they are. Meanings they do not draw take
carto's symbol in carto's colours, then a Maki or Temaki icon (CC0) in their colours. A code
topoactive marks with its plain label anchor, or none of these draws, gets that anchor square;
the rock 0x6614 is topoactive's own small ring.
The counts are in the header of `points.txt`.
