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

    /// A land polygon under everything, so a receiver never shows its own map background.
    /// `--generate-sea` with `land-tag=natural=land` produces one per tile; without a rule
    /// here the tiles drop it. Emitted as 0x27: mkgmap refuses 0x4a in a style rule.
    func addLandUnderEverything(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: land under everything"
        let rules = """


        \(marker) --------------------------------------------
        # The generate-sea land polygons. Resolution 17 puts them on every tile level,
        # so the ground is always a real polygon and never the device's own background.
        #
        # The TYP has to hold up its end, in a way a GPSMAP 67 never shows and a fenix
        # does: the background 0x4b must sit on a draw level of its OWN, below this type.
        # Sharing a level is not an order -- mkgmap writes a subdivision's shapes by
        # descending area, so two tile-sized polygons take turns and the watch goes black
        # at every zoom. Colouring the land red does not help: it is drawn, and lost.
        natural=land [\(StyleCatalog.landPolygonType) resolution 17]

        """
        guard try spliceRules(rules, marked: marker, intoFile: "polygons", in: directory)
        else { return }
        log.append("land drawn under everything, so the device background never shows")
    }

    func lowerWoodlandResolution(in directory: URL, log: Log) throws {
        let polygons = directory.appendingPathComponent("polygons")
        guard var text = try? String(contentsOf: polygons, encoding: .utf8) else { return }
        let edits = [
            ("landuse=forest | landuse=wood [0x50 resolution 20]",
             "landuse=forest | landuse=wood [0x50 resolution 18]"),
            ("natural=wood [0x50 resolution 20]", "natural=wood [0x50 resolution 18]"),
            ("natural=scrub [0x4f resolution 20]", "natural=scrub [0x4f resolution 18]")
        ]
        var done = 0
        for (old, new) in edits where text.contains(old) {
            text = text.replacingOccurrences(of: old, with: new)
            done += 1
        }
        guard done > 0 else {
            log.warn("woodland rules have changed in this mkgmap — left at their own zoom")
            return
        }
        try text.write(to: polygons, atomically: true, encoding: .utf8)
        log.append("woodland drawn from resolution 18, as the rest of the landcover is")
    }

    /// The three forest kinds, and the words a build labels them with.
    static func forestKinds(cyrillic: Bool)
        -> [(tag: String, type: String, suffix: String, alone: String)] {
        let words = StyleWords(cyrillic: cyrillic)
        return [("needleleaved", "0x57",
                 words("forest.coniferous-suffix"), words("forest.coniferous")),
                ("broadleaved", "0x58",
                 words("forest.broadleaved-suffix"), words("forest.broadleaved")),
                ("mixed", "0x50",
                 words("forest.mixed-suffix"), words("forest.mixed"))]
    }

    /// The six leaf-type rules exactly as `addForestTypeRules` writes them, at
    /// `resolution`. The overview diet matches these lines verbatim to move them, so
    /// both sides come from this one builder — in either language.
    static func forestTypeRuleLines(cyrillic: Bool, resolution: Int) -> [String] {
        let wood = "(landuse=forest | landuse=wood | natural=wood)"
        var out: [String] = []
        for k in forestKinds(cyrillic: cyrillic) {
            out.append("\(wood) & leaf_type=\(k.tag) & name=* "
                     + "{ name '${name} (\(k.suffix))' } [\(k.type) resolution \(resolution)]")
            out.append("\(wood) & leaf_type=\(k.tag) "
                     + "{ name '\(k.alone)' } [\(k.type) resolution \(resolution)]")
        }
        return out
    }

    /// Tells coniferous woodland from broadleaved, by OSM's `leaf_type`, in the fill and in
    /// the label. Mixed keeps 0x50, the both-symbols texture shared with forest of unknown
    /// kind. Most stands are unnamed, so an unnamed one takes the kind as its whole label.
    func addForestTypeRules(in directory: URL, cyrillic: Bool, log: Log) throws {
        let marker = "# --- kmap: forest by leaf type"
        let wood = "(landuse=forest | landuse=wood | natural=wood)"
        var rules = [marker + " ------------------------------------",
                     "# Every wood first lays a plain floor, 0x59, and carries on to its own",
                     "# type below. mkgmap merges neighbouring shapes of one type and never",
                     "# merges across types, so a broadleaved stand against a needleleaved one",
                     "# leaves two shapes that only touch -- and a GPSMAP 67 rounds the shared",
                     "# edge to a white hairline of map background. Traced to the exact",
                     "# 0x50/0x58 boundary in the built tile. The floor is flat colour, the one",
                     "# the three forest tiles already sit on, so the hairline shows forest.",
                     "\(wood) [0x59 resolution 18 continue]",
                     "# See addForestTypeRules. Before the stock rules, which type any wood",
                     "# alike, so a stand with leaf_type never reaches them.",
                     ""]
        rules.append(contentsOf: Self.forestTypeRuleLines(cyrillic: cyrillic, resolution: 18))
        rules.append("")
        rules.append("")

        switch try insertRules(rules.joined(separator: "\n"), marked: marker,
                               beforeLineWith: "landuse=forest | landuse=wood [0x50",
                               intoFile: "polygons", in: directory) {
        case .added:
            log.append("forest split by leaf type — "
                       + "\(Self.forestKinds(cyrillic: cyrillic).count) kinds")
        case .missingAnchor:
            log.warn("the stock forest rule was not found — leaf types left undrawn")
        case .leftAlone:
            break
        }
    }

    /// Ground cover the stock rule set leaves blank: `natural=grassland`, `natural=bare_rock`
    /// and `natural=scree` appear in no mkgmap rule. Each gets a type of its own;
    /// bare rock does not reuse 0x52, which is tundra.
    func addGroundCoverRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: ground cover"
        let rules = """


        \(marker) ------------------------------------------------
        # Landcover mkgmap's own rules do not mention at all.
        # Resolution 18 matches the neighbouring cover types (forest, scrub, sand), so the
        # treeline and the rock line appear together rather than at different zooms.

        # natural=fell is deliberately absent: a high plateau gets no flat fill of its own.
        # Its green rim in `lines` draws the shape and carries the name, and the
        # protected-area hatch above it is what should read inside — a tint under the
        # hatch only muddies it, and vendor styles do not fill the plateaux either.
        # Grassland alone: a meadow is already mkgmap's own 0x1c a few rules up, and
        # the clause this once carried for it (`landuse=meadow & natural=grassland`)
        # was a subset of the first and never drew a thing.
        natural=grassland [0x55 resolution 18]
        # A closed way tagged natural=stone is a boulder traced round rather than
        # dropped as a node -- 20 of them here, against 230 nodes. Same ground, so
        # the same fill; the nodes are handled in `points` below.
        natural=bare_rock | natural=rock & area=yes | natural=stone [0x56 resolution 18]
        natural=scree | natural=shingle [0x54 resolution 18]

        """
        guard try spliceRules(rules, marked: marker, intoFile: "polygons", in: directory)
        else { return }

        // The lone boulders go in `points` and nowhere else: 0x6614 is a POI type, and
        // mkgmap refuses the whole style if a polygon rule offers it.
        let pointRules = """


            \(marker) ------------------------------------------------
            # 230 lone boulders carry natural=stone, which no rule mentions; they are
            # landmarks on open ground and share the icon the 615 natural=rock points
            # already use, one line below in the stock file.

            natural=stone [0x6614 resolution 24]

            """
        try spliceRules(pointRules, marked: marker, intoFile: "points", in: directory)

        log.append("grassland, bare rock and scree given ground cover")
    }

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
                with: "leisure=nature_reserve [0x16 resolution 18]")

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
        try spliceRules(StyleCatalog.militaryEdgeRules, marked: "# --- kmap: military edge",
                        intoFile: "lines", in: directory)

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

            (type=multipolygon | type=boundary) & natural=fell
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
        (kmap:fell_edge=yes | natural=fell) & highway!=* {name '${name}'} [0x12 resolution 21 continue with_actions]

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

    /// Reclassifies natural springs tagged `amenity=drinking_water`, whose stock rule sits
    /// above the spring rules and wins. These rules only retag and assign no type, so the
    /// element carries on down the file to the spring rules, variants included.
    func addWaterSourceRules(in directory: URL, cyrillic: Bool,
                                     log: Log) throws {
        let words = StyleWords(cyrillic: cyrillic)
        let well = words("water.well-suffix")
        let wellAlone = words("water.well")
        let tap = words("water.tap-suffix")
        let tapAlone = words("water.tap")
        let geyserAlone = words("water.geyser")
        let marker = "# --- kmap: natural water sources"
        let rules = """
        \(marker) ---------------------------------------
        # Action-only: no type, so these fall through to the spring rules below.

        amenity=drinking_water & natural=spring { delete amenity }
        amenity=drinking_water & source_ref='http://rodnik.crimea.ua/' \
        { set natural='spring'; delete amenity }

        # A well is man-made, so it keeps the tap — but it is not a tap, and the card has
        # no type row on this device, so the kind goes in the label as it does for springs.
        #
        # 0x6414 is Garmin's own well symbol, taken from a vendor style. The type is set
        # here rather than through redirects.txt because these two lines are kmap's own and
        # their text is in the map's language: a redirect keyed on one language's wording
        # matches nothing on a build in another.
        man_made=water_well & name=* { name '${name} (\(well))' } [0x6414 resolution 24]
        man_made=water_well & name!=* { name '\(wellAlone)' } [0x6414 resolution 24]
        man_made=water_tap & name=* { name '${name} (\(tap))' }
        man_made=water_tap & name!=* { name '\(tapAlone)' }

        # Neither mkgmap's stock rules nor kmap's drew a geyser at all. 0x6509 is where a
        # receiver expects one -- 0x65 is Garmin's hydrography -- and the icon is a
        # vendor style's own, on the water blue used here.
        natural=geyser & name=* { name '${name}' } [0x6509 resolution 24]
        natural=geyser & name!=* { name '\(geyserAlone)' } [0x6509 resolution 24]

        """

        switch try insertRules(rules, marked: marker,
                               beforeLineWith: "amenity=drinking_water [0x5000",
                               intoFile: "points", in: directory) {
        case .added:
            log.append("natural water sources separated from taps")
        case .missingAnchor:
            log.warn("the stock amenity=drinking_water rule was not found — water sources"
                     + " left as they are")
        case .leftAlone:
            break
        }
    }

    /// Splits springs by what a walker needs before relying on one. All four types draw the
    /// same icon; the difference shows only in the object's card, through the TYP's type
    /// name. The rules must precede the stock `natural=spring` rule: first match wins.
    func addSpringVariantRules(in directory: URL, cyrillic: Bool,
                                       log: Log) throws {
        let marker = "# --- kmap: spring variants"

        // Written in the language the map is labelled in: a Cyrillic suffix on a Latin map
        // comes out as question marks under code page 1252.
        let words = StyleWords(cyrillic: cyrillic)
        let spring = words("spring.name")
        let undrinkable = words("spring.undrinkable")
        let boil = words("spring.boil")
        let intermittent = words("spring.intermittent")
        let seasonal = words("spring.seasonal")

        let rules = """


        \(marker) --------------------------------------------
        # Same drawing as 0x6511, but a distinct type — and the difference is spelled into
        # the label as well. The type name alone is not enough: a GPSMAP 67 does not show
        # the type row on the map-cursor card, so a walker deciding whether to rely on this
        # water would never see it. The suffix goes on the name, which is always drawn.
        # Ordered worst-news-first: undrinkable matters more than merely seasonal.

        natural=spring & drinking_water=no \
        { name '${name|def:\(spring)} (\(undrinkable))' } [0x6517 resolution 24]
        natural=spring & drinking_water=boil \
        { name '${name|def:\(spring)} (\(boil))' } [0x6517 resolution 24]
        natural=spring & intermittent=yes \
        { name '${name|def:\(spring)} (\(intermittent))' } [0x6516 resolution 24]
        natural=spring & seasonal=yes \
        { name '${name|def:\(spring)} (\(seasonal))' } [0x6515 resolution 24]

        """
        // Immediately before the stock rule, not above `<finalize>`: first match wins, and
        // anything spliced at the end of the file loses to a rule higher up.
        switch try insertRules(rules.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n",
                               marked: marker, beforeLineWith: "natural=spring [0x6511",
                               intoFile: "points", in: directory) {
        case .added:
            log.append("spring variants added to the rule set")
        case .missingAnchor:
            log.warn("the stock natural=spring rule was not found — spring variants skipped")
        case .leftAlone:
            break
        }
    }
}
