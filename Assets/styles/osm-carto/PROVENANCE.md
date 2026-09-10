# Where this style comes from

The palette is transcribed from **openstreetmap-carto** — the stylesheet that
draws openstreetmap.org itself.

    https://github.com/gravitystorm/openstreetmap-carto
    Licence: CC0 1.0 public domain dedication, and explicitly so for the look:
    "For avoidance of doubt, this includes the cartographic design."

CC0 means no conditions at all; the attribution here is courtesy and
traceability, not obligation. `LICENSE.md` beside this file quotes the
dedication in full. Colours were read from the project's own files
on 2026-08-30 (master): `style/road-colors-generated.mss` (road fills and
casings are generated there from `road-colors.yaml`), `style/landcover.mss`,
`style/water.mss`, `style/buildings.mss`, `style/style.mss`.

The icons come from the same repository's `symbols/` — CC0 like everything else
— rasterized with rsvg-convert and hand-tuned to Garmin bitmap sizes in kmap's
own pixel editor. Only the result is kept, in `points.txt`: the SVGs it was made
from are a fetch away, and the recipe is written down below.

`palette.txt` maps each colour onto the Garmin type codes kmap's rule set
emits. The codes are kmap's, read out of the materialized style; the colours
are carto's, verbatim.

## Icons

`points.txt` was generated from openstreetmap-carto's own symbols (`symbols/`
in the repository, CC0), fetched 2026-08-31: the SVGs were
rendered at 16 px with rsvg-convert, thresholded on alpha, ink colours taken
from carto's `style/amenity-points.mss` category colours (gastronomy #C77400,
amenity #734A08, health #BF0000, transportation #0092DA, shop #AC39AC,
religion #000000, landform #D08F55, water-text #576DDF). Night ink is the day
ink lifted two thirds towards white and snapped to the 0/85/170/255 steps a
MIP display can show. The type codes are the ones kmap's base rules emit,
read from the materialized rule set.

The lighthouse (`symbols/man_made/lighthouse.svg`) came later, on 2026-09-10,
when kmap gave lighthouses a number of their own: same repository, same recipe,
the mast's ink. Barriers keep no symbol here, as they never had one, though the
repository has drawings for them.
