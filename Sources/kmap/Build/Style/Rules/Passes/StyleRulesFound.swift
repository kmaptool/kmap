import Foundation

/// Rules for meanings other maps draw and this style had no rule for.
///
/// Each rule emits a code the style already uses for something of the same kind, so an
/// imported TYP draws it as it stands; a new code would need a TYP entry of its own.
extension StyleCatalog {
    static let foundPointMarker = "# --- kmap: drawn nowhere until now (points)"

    /// Points nothing drew: pylons, water towers, trig points, a lighthouse. One tag to a
    /// line, because the hide catalogue takes one entry per rule.
    static let foundPointRules = """


        \(foundPointMarker) ------------------------
        # Found by reading foreign maps against the ground they were made from: every
        # meaning here came back as "their style draws this, ours has no rule for it".
        # The codes are ones this style already emits, so any imported TYP draws them.

        # 0x6411 is the style's pylon. A wind turbine, a water tower and a trig point are
        # all a vertical thing standing in the open, and on the detail zoom only: there
        # are 240 000 pylons in western Russia alone.
        power=tower [0x6411 resolution 24]
        power=generator [0x6411 resolution 24]
        man_made=water_tower [0x6411 resolution 24]
        man_made=survey_point [0x6411 resolution 24]
        # A lighthouse is a landmark on a coast, not a pylon: its own number, drawn with
        # its own picture by the palettes and by every borrowed style that has one.
        man_made=lighthouse [0x6415 resolution 24]
        man_made=beacon [0x6411 resolution 24]
        highway=milestone [0x6411 resolution 24]

        # 0x0b00 is the hamlet. A locality is a named place with nobody living in it and
        # a dwelling is one household: both are names on a topo map and nothing more.
        place=locality & name=* [0x0b00 resolution 24]
        place=isolated_dwelling & name=* [0x0b00 resolution 24]

        # 0x3003 is the town hall; a government office is the same errand.
        office=government [0x3003 resolution 24]

        # 0x2f09 is the marina and the ferry pier, where a boat meets the shore.
        leisure=slipway [0x2f09 resolution 24]

        # 0x2c08 is the sports pitch; a bunker stands with the ruins and the digs.
        leisure=fishing [0x2c08 resolution 24]
        military=bunker [0x2c02 resolution 24]

        """

    func addFoundPointRules(in directory: URL, log: Log) throws {
        guard
            try spliceRules(
                StyleCatalog.foundPointRules,
                marked: StyleCatalog.foundPointMarker,
                intoFile: "points",
                in: directory
            )
        else { return }
        log.append("pylons, trig points and eight other point kinds added to the rule set")
    }

    static let foundLineMarker = "# --- kmap: drawn nowhere until now (lines)"

    /// Lines nothing drew: tree rows, groynes, dykes, and the railways that are no
    /// longer railways.
    static let foundLineRules = """


        \(foundLineMarker) -------------------------
        # As above: meanings foreign maps draw and this style had no rule for.

        # 0x17 is the fence, the wall and the breakwater: a thin line that is
        # a thing on the ground rather than a way across it. Non-routable, which is why
        # an abandoned railway belongs here and not among the paths: walked or not, it
        # is not a way the router may send anybody down.
        natural=tree_row [0x17 resolution 24]
        man_made=groyne [0x17 resolution 23]
        man_made=dyke [0x17 resolution 23]
        railway=abandoned | railway=razed | railway=dismantled [0x17 resolution 23]

        """

    static let foundWaterwayMarker = "# --- kmap: drawn nowhere until now (waterways)"

    /// Water lines the stock mop-up would draw as a stream that runs dry: ditches, dams, weirs.
    static let foundWaterwayRules = """
        \(foundWaterwayMarker) ---------------------
        # 0x18 is the stream. A ditch is the same water in a dug channel, one zoom step
        # in because there are a great many of them; 0x26 where it runs dry, as a stream.
        waterway=ditch & intermittent=yes [0x26 resolution 23]
        waterway=ditch [0x18 resolution 23]
        # 0x17 is the fence and the wall: a dam and a weir are built across the water.
        waterway=dam [0x17 resolution 22]
        waterway=weir [0x17 resolution 23]
        """

    func addFoundLineRules(in directory: URL, log: Log) throws {
        let lines = try spliceRules(
            StyleCatalog.foundLineRules,
            marked: StyleCatalog.foundLineMarker,
            intoFile: "lines",
            in: directory
        )
        let waterways = try spliceRules(
            StyleCatalog.foundWaterwayRules,
            marked: StyleCatalog.foundWaterwayMarker,
            aheadOfEvery: "waterway",
            intoFile: "lines",
            in: directory
        )
        guard lines || waterways else { return }
        log.append("ditches, tree rows, dams and abandoned railways added to the rule set")
    }

    static let foundPolygonMarker = "# --- kmap: drawn nowhere until now (polygons)"

    /// Polygons nothing drew: aprons, platforms, landfill, heath.
    static let foundPolygonRules = """


        \(foundPolygonMarker) ----------------------
        # As above. These sit after the stock rules, so anything already claimed by a
        # rule further up is drawn by that one.

        # 0x25 is the pedestrian area: a platform is paved ground somebody stands on.
        # 0x0e is the runway, and an apron is its concrete.
        railway=platform [0x25 resolution 23]
        aeroway=apron [0x0e resolution 21]

        # 0x0c is the industrial estate; a landfill is worked ground of
        # the same sort. 0x05 is the car park, which is what a service yard looks like.
        landuse=landfill [0x0c resolution 20]
        highway=service & (area=yes | mkgmap:mp_created=true) [0x05 resolution 23]

        # 0x4f is scrub: heath is the low cover of the same picture.
        natural=heath [0x4f resolution 21]

        """

    /// Polygons a stock rule for every value of their key would draw as something
    /// nameless: each block goes ahead of that rule.
    static let foundAheadOfEvery: [(key: String, marker: String, rules: String)] = [
        (
            "man_made", "# --- kmap: drawn nowhere until now (man-made areas)",
            """
            # 0x25 is the pedestrian area: a pier and a breakwater are paved ground
            # somebody stands on.
            man_made=pier [0x25 resolution 22]
            man_made=breakwater [0x25 resolution 22]
            """
        ),
        (
            "tourism", "# --- kmap: drawn nowhere until now (tourism areas)",
            """
            # 0x17 is the park, and a picnic site is a park with a table in it.
            tourism=picnic_site [0x17 resolution 23]
            """
        )
    ]

    func addFoundPolygonRules(in directory: URL, log: Log) throws {
        var added = try spliceRules(
            StyleCatalog.foundPolygonRules,
            marked: StyleCatalog.foundPolygonMarker,
            intoFile: "polygons",
            in: directory
        )
        for block in StyleCatalog.foundAheadOfEvery {
            let went = try spliceRules(
                block.marker + " ---\n" + block.rules,
                marked: block.marker,
                aheadOfEvery: block.key,
                intoFile: "polygons",
                in: directory
            )
            added = added || went
        }
        guard added else { return }
        log.append("aprons, platforms, piers and 5 other polygon kinds added to the rule set")
    }
}
