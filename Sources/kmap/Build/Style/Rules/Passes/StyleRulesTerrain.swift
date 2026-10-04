import Foundation

/// Rules about what the ground is made of: woodland, protected land, plateaux, cliffs,
/// water and springs. Each reads and rewrites the style's `polygons` and `lines` files in
/// place.
extension StyleCatalog {
    /// The red edge of closed military ground, drawn at the resolution of the fill it
    /// encloses. The restricted ground sits at 18; the facilities stay later.
    static let militaryEdgeRules = """


        # --- kmap: military edge ---------------------------------------------
        # 0x2d is unused by the stock style.

        # `continue`, and the marker, for the same two reasons as the conservation
        # outlines above: without it the edge would eat the zone's own fill, and
        # with it a way tagged both landuse=military and military=range would be
        # outlined twice.

        landuse=military {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]
        military=danger_area & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]
        military=range & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]
        military=airfield & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 20 continue with_actions]
        military=base & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 20 continue with_actions]
        military=barracks & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 23 continue with_actions]

        """

    /// Makes conservation areas visible. The mkgmap default style has one rule here,
    /// `leisure=nature_reserve`, and none for `boundary=protected_area` or
    /// `boundary=national_park`. All three take polygon type 0x16, at a lower resolution.
    func addProtectedAreaRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: conservation areas"
        let rules = """


            \(marker) ---------------------------------------------
            # Added by kmap. The stock style only knows leisure=nature_reserve, so every
            # boundary=protected_area and boundary=national_park renders as nothing.
            #
            # One fill for all of them, 0x16, carrying a green diagonal hatch: it hatches
            # every protected area alike, and a strict reserve is not a different kind of
            # ground for being closed. The edge is drawn from `lines`, one green
            # ribbon for all of them.

            boundary=national_park [0x16 resolution 18]
            boundary=protected_area [0x16 resolution 18]
            leisure=nature_reserve [0x16 resolution 18]

            """

        var added = false
        try amendRuleFile("polygons", in: directory, unlessMarked: marker) { text in
            // Show reserves a zoom level earlier than stock.
            text = text.replacingOccurrences(
                of: "leisure=nature_reserve [0x16 resolution 19]",
                with: "leisure=nature_reserve [0x16 resolution 18]"
            )

            // And the closed military ground alongside them, at the same resolution.
            text = StyleCatalog.restrictedMilitary(in: text).text

            splice(rules, into: &text)
            added = true
            return true
        }
        guard added else { return }

        // The fill says a zone exists but not where its edge runs. Closed ways reach the
        // line rules too, so the same tags can carry a dashed outline and the name.
        let lineRules = """


            \(marker) ---------------------------------------------
            # One outline for every protected area, the green band 0x19, unused by the
            # stock style. Drawn from the same resolution as the fill: the hatch says a
            # protected area is about, the edge says where it runs.
            #
            # `continue` is required. mkgmap offers a closed way to the line rules first,
            # and a plain typed match there ends the way's journey before it reaches the
            # polygon rules, so the outline deletes the fill of every protected area.
            # With it, three test ways give 12 shapes and 9 lines; without it, 9 lines.
            #
            # The marker tag guards a way carrying both boundary=protected_area and
            # leisure=nature_reserve, which would draw the same band over itself twice.
            #
            # `with_actions` is required too: a bare `continue` carries the way onward but
            # skips the rule's actions, dropping both the marker and the name.


            boundary=national_park & kmap:zone_edge!=* {name '${name}'; set kmap:zone_edge=yes} [0x19 resolution 18 continue with_actions]
            boundary=protected_area & kmap:zone_edge!=* {name '${name}'; set kmap:zone_edge=yes} [0x19 resolution 18 continue with_actions]
            leisure=nature_reserve & kmap:zone_edge!=* {name '${name}'; set kmap:zone_edge=yes} [0x19 resolution 18 continue with_actions]

            """
        try spliceRules(lineRules, marked: marker, intoFile: "lines", in: directory)

        // The military edge, which the stock style draws not at all: the hatch says what
        // the ground is, the line says where it starts.
        try spliceRules(
            StyleCatalog.militaryEdgeRules,
            marked: "# --- kmap: military edge",
            intoFile: "lines",
            in: directory
        )

        log.append("conservation areas added to the rule set")
    }

    /// Draws the rim of a plateau, so the `natural=fell` fill has a visible edge. The tag
    /// arrives as a closed way, which mkgmap offers to the line rules, or as a multipolygon,
    /// whose members need it pushed on from `relations`. `highway!=*` spares walked rims.
    func addPlateauEdgeRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: plateau rim"

        try amendRuleFile("relations", in: directory, unlessMarked: marker) { text in
            text += """


                \(marker) ---------------------------------------------
                # Member ways of a fell multipolygon carry no tags, so the outline rule in
                # `lines` would never see them. This hands each member the marker it matches on.
                # Named plateaux only; see the rule in `lines`.

                (type=multipolygon | type=boundary) & natural=fell & name=*
                { apply { set kmap:fell_edge=yes } }

                """
            return true
        }

        let rules = """


            \(marker) ---------------------------------------------
            # 0x12 is unused by the stock style. Detail zoom only — a rim at overview scale
            # is noise.
            #
            # The type code is chosen, not arbitrary. Where a plateau edge runs along a
            # reserve boundary the two lines land on the same pixels, and the device draws
            # the higher type code last: as 0x2c the rim covered the reserve edge entirely.
            # Below 0x19 it now goes underneath, so the reserve always wins the overlap.

            # `continue` for the same reason as the conservation outlines: a plain typed
            # match in `lines` ends a closed way's journey and it never reaches the polygon
            # rules, so without it this rim would delete the plateau's own fill.
            #
            # Named fells only. The rim is for the yaylas, whose name it draws along the
            # edge. natural=fell is also put on nameless patches of alpine meadow, where a
            # rim reads as a fence or a reserve edge; those get the fill alone, like a
            # grassland.
            (kmap:fell_edge=yes | (natural=fell & name=*)) & highway!=* {name '${name}'} [0x12 resolution 21 continue with_actions]

            """
        guard try spliceRules(rules, marked: marker, intoFile: "lines", in: directory)
        else { return }
        log.append("plateau rim outline added to the rule set")
    }

    /// Landforms the mkgmap default style draws as nothing: the named valley and the
    /// cutline. A valley is drawn as faintly as the format allows, being carried for the
    /// label riding along it; a cutline is drawn for itself.
    func addLandformRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: landforms"
        let rules = """


            \(marker) ---------------------------------------------
            # 0x23 and 0x24 are unused by the stock style, by the TYP's lines and by every
            # tile, and -- the part that is load-bearing -- they are OUTSIDE mkgmap's set of
            # "special routable" line types (0x01-0x13, 0x16, 0x1a, 0x1b, 0x2c-0x2f), which
            # Garmin firmware may try to route along. These two lived at 0x2e/0x2f and every
            # forest track running along its cutline -- one way, both tags -- drew a
            # routable road and a non-routable 0x2e on the same way: mkgmap's SEVERE
            # "leads to routing errors", two tiles of the Caucasus build. Detail zoom only
            # for the valley -- its name is long and there are 158 of them.

            man_made=cutline [0x23 resolution 21]
            natural=valley & name=* { name '${name}' } [0x24 resolution 20]

            """

        guard try spliceRules(rules, marked: marker, intoFile: "lines", in: directory)
        else { return }
        log.append("valleys and cutlines added to the rule set")
    }

    /// Cliffs and crags, which the mkgmap default style draws nowhere: `natural=cliff` has no
    /// line rule, and only a named cliff produces a point (0x6607). The line is emitted as
    /// `0x2b`; `arete` and `ridge` take the same type.
    func addCliffRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: cliffs"
        let rules = """


            \(marker) ------------------------------------------------------
            # The stock style has no natural=cliff line rule, so crags are invisible.
            # 0x2b is unused by it and free in every TYP checked.

            natural=cliff {name '${name}'} [0x2b resolution 22]
            natural=arete | natural=ridge {name '${name}'} [0x2b resolution 22]
            # Deliberately NOT man_made=embankment or barrier=retaining_wall. In a 60 000 km²
            # extract those are 2785 ways against 2956 real crags — enough to halve the
            # symbol's meaning.
            # A retaining wall is not a cliff, and on a walking map that distinction is the
            # whole point of drawing it.

            """
        guard try spliceRules(rules, marked: marker, intoFile: "lines", in: directory)
        else { return }
        log.append("cliffs added to the rule set")
    }
}
