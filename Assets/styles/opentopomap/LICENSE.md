# OpenTopoMap style — licence

The drawings in `points.txt` and `graphics.txt` are OpenTopoMap's own, taken verbatim from
`garmin/style/typ/opentopomap.txt` in <https://github.com/der-stefan/OpenTopoMap>. The
colours in `palette.txt` were read from the same file. See `PROVENANCE.md` for exactly what
was taken and what was changed.

    https://github.com/der-stefan/OpenTopoMap
    CC-BY-SA — © OpenTopoMap, https://opentopomap.org
    But see below: upstream also calls its Garmin maps CC-BY-NC-SA.

## What upstream states, and where

The project says two different things, and they are quoted here rather than summarised,
because which one governs the TYP source is not obvious. Both were read on 2026-09-08.

The repository's own `LICENCE` file, at the root of `der-stefan/OpenTopoMap`, contains one
line and no version number:

    CC-BY-SA

The repository's `README.md` distinguishes the rendered maps from the online one. Of the
online raster map it says the licence is CC-BY-SA. Of the Garmin edition it says:

> The license of the Garmin maps is CC-BY-NC-SA and therefore reselling is not allowed.

Neither `garmin/README.md` nor the TYP source itself carries a licence header, so the
repository cannot settle the question from the inside.

## How kmap reads it, and what that means for you

The narrow reading is that "the Garmin maps" are the finished `.img` products distributed
from garmin.opentopomap.org — which carry map data as well as a look — and that the style
source inside the repository falls under the repository's own `LICENCE`, CC-BY-SA. That is
the reading kmap ships on.

The wider reading is that the whole Garmin edition, its style included, is
CC-BY-NC-SA. **If that reading is the right one, a map you build with this style may not be
sold.** kmap cannot resolve this for you, and nothing here is legal advice. If you intend
to sell maps, either ask OpenTopoMap directly or build with a different style: `osm-carto`
is CC0 and carries no such question.

Under either reading the attribution is the same and is not optional. kmap writes
`Style: OpenTopoMap, CC-BY-SA` into every map built with this style, the file headers name
the source, and this folder records where each piece came from.

## The licence text

Upstream names no version, so none is assumed here. The Creative Commons texts are at
<https://creativecommons.org/licenses/>: BY-SA at `/by-sa/4.0/` and its earlier versions,
BY-NC-SA at `/by-nc-sa/4.0/`.
