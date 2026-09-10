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

        # 0x6411 is the style's mast and tower. A pylon, a wind turbine, a water tower
        # and a trig point are all a vertical thing standing in the open, and on the
        # detail zoom only: there are 240 000 pylons in western Russia alone.
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
        # a dwelling is one household — both are names on a topo map and nothing more.
        place=locality & name=* [0x0b00 resolution 24]
        place=isolated_dwelling & name=* [0x0b00 resolution 24]

        # 0x3003 is the town hall; a government office is the same errand.
        office=government [0x3003 resolution 24]

        # 0x2f09 is the marina and the ferry pier — where a boat meets the shore.
        leisure=slipway [0x2f09 resolution 24]

        # 0x2c08 is the sports pitch, 0x2c02 the ruin and the dig.
        leisure=fishing [0x2c08 resolution 24]
        military=bunker [0x2c02 resolution 24]

        """

    func addFoundPointRules(in directory: URL, log: Log) throws {
        guard try spliceRules(StyleCatalog.foundPointRules, marked: StyleCatalog.foundPointMarker,
                              intoFile: "points", in: directory) else { return }
        log.append("pylons, trig points and eight other point kinds added to the rule set")
    }

    static let foundLineMarker = "# --- kmap: drawn nowhere until now (lines)"

    /// Lines nothing drew: ditches, tree rows, dams, weirs, groynes, dykes, and the
    /// railways that are no longer railways.
    static let foundLineRules = """


        \(foundLineMarker) -------------------------
        # As above: meanings foreign maps draw and this style had no rule for. The style
        # names several of these in Russian a few hundred lines up — `waterway=ditch &
        # name!=* { name 'Канава' }` — and then never drew them.

        # 0x18 is the stream and the drain. A ditch is the same water in a dug channel,
        # one zoom step in because there are a great many of them.
        waterway=ditch [0x18 resolution 23]

        # 0x17 is the fence, the wall, the hedge and the breakwater: a thin line that is
        # a thing on the ground rather than a way across it. Non-routable, which is why
        # an abandoned railway belongs here and not among the paths — walked or not, it
        # is not a way the router may send anybody down.
        natural=tree_row [0x17 resolution 24]
        waterway=dam [0x17 resolution 22]
        waterway=weir [0x17 resolution 23]
        man_made=groyne [0x17 resolution 23]
        man_made=dyke [0x17 resolution 23]
        railway=abandoned | railway=razed | railway=dismantled [0x17 resolution 23]

        """

    func addFoundLineRules(in directory: URL, log: Log) throws {
        guard try spliceRules(StyleCatalog.foundLineRules, marked: StyleCatalog.foundLineMarker,
                              intoFile: "lines", in: directory) else { return }
        log.append("ditches, tree rows, dams and abandoned railways added to the rule set")
    }

    static let foundPolygonMarker = "# --- kmap: drawn nowhere until now (polygons)"

    /// Polygons nothing drew: aprons, platforms, piers, landfill, heath, picnic sites,
    /// and the church that is a church rather than a building.
    static let foundPolygonRules = """


        \(foundPolygonMarker) ----------------------
        # As above. These sit after the stock rules, so anything already claimed by a
        # rule further up — a church that is also `building=yes` — is drawn by that one.

        # 0x25 is the pedestrian area: a pier, a platform and a breakwater are all paved
        # ground somebody stands on. 0x0e is the runway, and an apron is its concrete.
        man_made=pier [0x25 resolution 22]
        railway=platform [0x25 resolution 23]
        man_made=breakwater [0x25 resolution 22]
        aeroway=apron [0x0e resolution 21]

        # 0x0c is the quarry and the industrial estate; a landfill is worked ground of
        # the same sort. 0x05 is the car park, which is what a service yard looks like.
        landuse=landfill [0x0c resolution 20]
        highway=service & (area=yes | mkgmap:mp_created=true) [0x05 resolution 23]

        # 0x4f is scrub — heath is the low cover of the same picture. 0x17 is the park,
        # and a picnic site is a park with a table in it.
        natural=heath [0x4f resolution 21]
        tourism=picnic_site [0x17 resolution 23]

        # 0x13 is the building. A church mapped as an outline with no `building` tag is
        # a building all the same, and 145 of them in western Russia went undrawn.
        amenity=place_of_worship [0x13 resolution 24]
        amenity=monastery [0x13 resolution 24]

        """

    func addFoundPolygonRules(in directory: URL, log: Log) throws {
        guard try spliceRules(StyleCatalog.foundPolygonRules, marked: StyleCatalog.foundPolygonMarker,
                              intoFile: "polygons", in: directory) else { return }
        log.append("aprons, platforms, piers and six other polygon kinds added to the rule set")
    }
}
