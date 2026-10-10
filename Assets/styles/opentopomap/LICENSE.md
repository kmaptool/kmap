# OpenTopoMap web style: licence

The colours in `palette.txt`, the dashes and patterns in `graphics.txt` and the icons in
`points.txt` come from **OpenTopoMap's raster style**, the Mapnik stylesheet in the folder
`mapnik/` of <https://github.com/der-stefan/OpenTopoMap>, and from the images in its
`mapnik/symbols-otm/`. The images are adapted into TYP bitmaps: a pixel is kept or left
out by its opacity, a translucent ink is composited into one opaque colour, a forest tile
becomes one mask in one colour, a line pattern is cut to its rows and a larger tile to a
32 x 32 window; kmap adds night colours and moves each drawing onto the type code whose
meaning it has, and keeps their 2 SVG symbols. Their pixel-art symbols are too small to
enlarge: the icons in `points.txt` are openstreetmap-carto's vectors (CC0) in their
colours, else carto's symbols, else Maki (Mapbox) or Temaki (Rapid) icons (both CC0), else
the plain anchor square of kmap's own reference TYP; none of those is theirs. See
`PROVENANCE.md` for exactly what was taken and how.

    https://github.com/der-stefan/OpenTopoMap
    CC-BY-SA, (c) OpenTopoMap, https://opentopomap.org

## What upstream states

The repository's `LICENCE` file, at commit 60c50cb8329d67c8556cd9f25b4a8e50bfc19c91,
contains one line and no version number:

    CC-BY-SA

Its `README.md` says of the online raster map, the one this style transcribes, that its
licence is CC-BY-SA. The CC-BY-NC-SA it names applies to the Garmin maps from
garmin.opentopomap.org, which this style is not made from.

## What that means for you

CC-BY-SA asks for attribution and that adaptations be shared under the same licence. Every
map built with this style carries the attribution `Style: OpenTopoMap, CC-BY-SA` beside the
OSM one; the file headers name the source too. The style files here are an adaptation and
stay under CC-BY-SA.

This covers the *style* only. Map data is OpenStreetMap and stays under the ODbL whatever
style is drawn over it; see the repository's `NOTICE.md`.

## The licence text

Upstream names no version, so none is assumed here. The Creative Commons texts are at
<https://creativecommons.org/licenses/>: BY-SA at `/by-sa/4.0/` and its earlier versions.
