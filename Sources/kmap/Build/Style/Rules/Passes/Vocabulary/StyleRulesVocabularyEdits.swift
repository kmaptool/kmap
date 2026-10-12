import Foundation

extension StyleCatalog {
    /// Stock rules moved onto a number of their own: the name logged, the rule file, the
    /// stock text and what replaces it, applied in this order.
    static let renumberedStockRules: [(name: String, file: String, old: String, new: String)] = [
        // Steps are retagged into a footway before any drawing rule sees them. Drawn on
        // their own number first, and routable: a staircase is still a way through.
        (
            "steps", "lines",
            """
            highway=steps | highway=corridor | highway=stepping_stones | highway=elevator | highway=escalator | highway=platform
                {set highway=footway; add bicycle=no}
            """,
            """
            # kmap: steps keep a number of their own — a style that draws a
            # staircase apart from a footpath has somewhere to put it.
            highway=steps [0x0f road_class=0 road_speed=0 resolution 24]
            highway=corridor | highway=stepping_stones | highway=elevator | highway=escalator | highway=platform
                {set highway=footway; add bicycle=no}
            """
        ),
        // Allotments and an orchard are both 0x4e in the stock rules; the dacha plots
        // around a Russian town are neither an orchard nor invisible.
        (
            "allotments", "polygons", "landuse=allotments [0x4e resolution 21]",
            "landuse=allotments [0x5a resolution 21]  # kmap: not the orchard's number"
        ),
        // A row of trees shared the number of dams, weirs and fences.
        (
            "tree row", "lines", "natural=tree_row [0x17 resolution 24]",
            "natural=tree_row [0x31 resolution 24]  # kmap: not the fence's number"
        ),
        // Ground kmap drew as its neighbour: a quarry is not an industrial estate, a
        // vineyard not an orchard, heath not scrub.
        (
            "quarry", "polygons", "landuse=quarry [0x0c resolution 19]",
            "landuse=quarry [0x0d resolution 19]  # kmap: not the industrial estate's number"
        ),
        (
            "vineyard", "polygons", "landuse=vineyard [0x4e resolution 20]",
            "landuse=vineyard [0x1b resolution 20]  # kmap: not the orchard's number"
        ),
        (
            "heath", "polygons", "natural=heath [0x4f resolution 21]",
            "natural=heath [0x1e resolution 21]  # kmap: not the scrub's number"
        ),
        // Ways kmap drew as their neighbour. The two that carry traffic keep a plain
        // number a receiver will route on.
        // Still on mkgmap's own rung here: `showTrailsEarlier` moves it to 22 later,
        // and knows the number this gives it.
        (
            "path", "lines", "highway=path [0x16 road_class=0 road_speed=0 resolution 23]",
            "highway=path [0x0e road_class=0 road_speed=0 resolution 23]"
                + "  # kmap: not the footway's number"
        ),
        (
            "living street", "lines", "highway=living_street [0x06 road_class=0 road_speed=1 resolution 22]",
            "highway=living_street [0x10 road_class=0 road_speed=1 resolution 22]"
                + "  # kmap: not the minor road's number"
        ),
        (
            "canal", "lines", "waterway=canal [0x1f resolution 21]",
            "waterway=canal [0x33 resolution 21]  # kmap: not the river's number"
        ),
        (
            "drain", "lines", "waterway=stream | waterway=drain [0x18 resolution 22]",
            "waterway=stream [0x18 resolution 22]\n"
                + "waterway=drain [0x34 resolution 22]  # kmap: not the stream's number"
        ),
        (
            "ditch", "lines", "waterway=ditch [0x18 resolution 23]",
            "waterway=ditch [0x35 resolution 23]  # kmap: not the stream's number"
        ),
        (
            "tram", "lines",
            "(railway=rail | railway=tram | railway=disused | railway=subway | railway=narrow_gauge"
                + " | railway=light_rail | railway=preserved) & !(tunnel=yes)\n    [0x14 resolution 22]",
            "railway=tram & !(tunnel=yes) [0x36 resolution 22]  # kmap: not the railway's number\n"
                + "(railway=rail | railway=disused | railway=subway | railway=narrow_gauge"
                + " | railway=light_rail | railway=preserved) & !(tunnel=yes)\n    [0x14 resolution 22]"
        ),
        // A tower and a mast each on a number of its own, not the pylon's.
        (
            "tower", "points",
            "man_made=tower | man_made=mast | landmark=chimney [0x6411 resolution 24]",
            "man_made=tower [0x6608 resolution 24]  # kmap: not the mast's number\n"
                + "man_made=mast | landmark=chimney [0x6609 resolution 24]  # kmap: not the pylon's number"
        ),
        // A hamlet is not a locality: one is a place people live in, the other a name on
        // empty ground, and a borrowed style draws them apart.
        (
            "hamlet", "points", "place=hamlet                     & name=* [0x0b00 resolution 24]",
            "place=hamlet                     & name=* [0x0d00 resolution 24]  # kmap: not the locality's number"
        )
    ]

    private static let groundLayer = "# --- kmap: ground a borrowed style may draw"
    private static let wallLayer = "# --- kmap: city wall"
    private static let outlineLayer = "# --- kmap: building outlines"

    /// Rules for what kmap drew as nothing at all, spliced in once under their marker:
    /// the name logged, the rule file, the marker and the text.
    static let addedLayers: [(name: String, file: String, marker: String, text: String)] = [
        // Ground kmap drew as nothing at all, each on the rung its kindred sit on.
        (
            "plateau, salt pond, greenhouses", "polygons", groundLayer,
            """


            \(groundLayer) ------------------------------------
            # None of kmap's own palettes paints these yet, and a number no palette paints
            # draws nothing at all — so a style that has a picture for a plateau or a salt
            # pond shows one, and every other style is exactly as it was.

            natural=fell [0x1f resolution 19]
            landuse=salt_pond [0x28 resolution 20]
            landuse=greenhouse_horticulture | landuse=greenhouse [0x29 resolution 21]

            """
        ),
        (
            "city wall", "lines", wallLayer,
            """


            \(wallLayer) ---------------------------------------------------
            # A city wall is a landmark, not a fence: kmap drew it as neither.

            barrier=city_wall [0x32 resolution 22]

            """
        ),
        // A building's outline as a line of its own: styles that draw one do it over the
        // fill, so the rule continues and the polygon rules still lay the fill down.
        (
            "building outlines", "lines", outlineLayer,
            """


            \(outlineLayer) --------------------------------------------
            # A borrowed style may draw the outline of a building as a line over the fill.
            # `continue` so the way still reaches the polygon rules and keeps its fill.

            building=* & building!=no [0x2f resolution 24 continue]

            """
        )
    ]
}
