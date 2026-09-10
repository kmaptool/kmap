import Foundation

/// Rules about the lines a route follows, and what stands in the way: trails and their
/// warnings, gates and access, parking, cableways, and the link a road under repair keeps
/// to its neighbours. These shape the routing graph as much as what is drawn.
extension StyleCatalog {
    /// Aerialways, which the stock style leaves undrawn: one line type, 0x25, for the
    /// whole family, and not routable. Written in the map's own language.
    static func aerialwayLineRules(cyrillic: Bool) -> String {
        let words = StyleWords(cyrillic: cyrillic)
        let cableCar = words("aerialway.cable-car")
        let chairLift = words("aerialway.chairlift")
        let dragLift = words("aerialway.drag-lift")
        let zipLine = words("aerialway.zip-line")
        return """


    # --- kmap: aerialways ---------------------------------------------
    # One line type for the whole family, 0x25: dark cable with crossbars,
    # oriented along the line (see the TYP). Not routable, on purpose: nobody
    # walks a cableway. Values with a hyphen are OSM's own spellings.

    (aerialway=cable_car | aerialway=gondola | aerialway=mixed_lift | aerialway=funicular) & name!=* { name '\(cableCar)' }
    aerialway=chair_lift & name!=* { name '\(chairLift)' }
    (aerialway=drag_lift | aerialway=t-bar | aerialway=j-bar | aerialway=platter | aerialway=rope_tow | aerialway=magic_carpet) & name!=* { name '\(dragLift)' }
    aerialway=zip_line & name!=* { name '\(zipLine)' }

    (aerialway=cable_car | aerialway=gondola | aerialway=mixed_lift | aerialway=funicular | aerialway=chair_lift) [0x25 resolution 20]
    (aerialway=drag_lift | aerialway=t-bar | aerialway=j-bar | aerialway=platter | aerialway=rope_tow | aerialway=magic_carpet | aerialway=zip_line) [0x25 resolution 21]
    aerialway=goods [0x25 resolution 23]
    """
    }

    /// Moves paths and tracks onto resolution 22, level 1 of the ladder. Lines only: the
    /// POI rules already sit at 22 after the zoom shift. Runs after every rule addition
    /// and after the shift, or it matches rules that do not exist yet.
    func showTrailsEarlier(in directory: URL, log: Log) throws {
        var touched = 0

        // Lines: exact rules, so a changed mkgmap is noticed rather than half-patched.
        let lineEdits = [
            "highway=path [0x0e road_class=0 road_speed=0 resolution 23]"
                + "  # kmap: not the footway's number",
            "highway=track [0x0a road_class=0 road_speed=1 resolution 22]",
            "highway=unsurfaced [0x0a road_class=0 road_speed=1 resolution 22]",
            "highway=bridleway [0x07 road_class=0 road_speed=0 resolution 23]",
            "highway=cycleway [0x11 road_class=0 road_speed=1 resolution 23]",
            "highway=via_ferrata [0x2b resolution 22]",
            "natural=cliff {name '${name}'} [0x2b resolution 22]",
            "man_made=cutline [0x23 resolution 21]",
            "(kmap:fell_edge=yes | natural=fell) & highway!=* {name '${name}'} "
                + "[0x12 resolution 21 continue with_actions]"
        ]
        let lines = directory.appendingPathComponent("lines")
        if var text = try? String(contentsOf: lines, encoding: .utf8) {
            var missed: [String] = []
            for rule in lineEdits {
                guard let cut = rule.range(of: "resolution ") else { continue }
                let head = String(rule[rule.startIndex..<cut.upperBound])
                let tail = String(rule[cut.upperBound...]).drop(while: { $0.isNumber })
                let replacement = head + "22" + tail
                if text.contains(rule) {
                    text = text.replacingOccurrences(of: rule, with: replacement)
                    touched += 1
                } else {
                    missed.append(String(rule.prefix(28)))
                }
            }
            try text.write(to: lines, atomically: true, encoding: .utf8)
            for m in missed { log.warn("rule not found, left at its own zoom — \(m)") }
        }

        guard touched > 0 else {
            log.warn("trail and landmark rules have changed — left at their own zoom")
            return
        }
        log.append("\(touched) trail rule(s) drawn from resolution 22")
    }

    /// Warnings that belong on the trail itself: where a path stops being a path, where it
    /// stops being walking, and where it is a via ferrata. Emitted as lines, so the warning
    /// is drawn along the way; the stock style deletes `highway=via_ferrata` outright.
    func addTrailWarningRules(in directory: URL, cyrillic: Bool,
                                      log: Log) throws {
        let marker = "# --- kmap: trail warnings"

        let words = StyleWords(cyrillic: cyrillic)
        let lost = words("trail.lost")
        let faint = words("trail.faint")
        let alpine = words("trail.alpine")
        let hard = words("trail.hard")
        let ferrata = words("trail.ferrata")
        let fordPlain = words("trail.ford")
        let fordStones = words("trail.ford-stones")

        func pair(_ condition: String, _ suffix: String) -> String {
            "\(condition) & name=* { name '${name} (\(suffix))' }\n"
            + "\(condition) & name!=* { name '\(suffix)' }"
        }

        let rules = """


        \(marker) ---------------------------------------------
        # Action-only and first in the file, so the highway rules below still draw the way.

        \(pair("(trail_visibility=no | trail_visibility=horrible)", lost))
        \(pair("trail_visibility=bad", faint))
        \(pair("(sac_scale=alpine_hiking | sac_scale=demanding_alpine_hiking"
                + " | sac_scale=difficult_alpine_hiking)", alpine))
        \(pair("sac_scale=demanding_mountain_hiking", hard))
        \(pair("(highway=via_ferrata | sport=via_ferrata | via_ferrata_scale=*)", ferrata))

        # 57 fords in the extract are tagged on the way rather than on a node, so the point
        # rules never see them. The way keeps whatever type its highway tag earns; this only
        # writes the label, which is the part that tells you your boots are about to get wet.
        \(pair("ford=stepping_stones", fordStones))
        \(pair("(ford=yes | ford=stream)", fordPlain))

        """

        // First in the file: these only set a label, and the typed highway rules below
        // would consume the way, `highway=via_ferrata {delete highway}` included.
        guard try prependRules(rules + "\n", marked: marker, toFile: "lines", in: directory)
        else { return }
        log.append("trail visibility, difficulty and via ferrata warnings added")
    }

    /// Names each barrier in the map's own language and says when it cannot be passed,
    /// both through the barrier's label. The name is set here, not appended later: `add
    /// name=` below is a no-op once a name exists. These rules carry no type of their own.
    func addBarrierAccessRules(in directory: URL, cyrillic: Bool,
                                       log: Log) throws {
        let marker = "# --- kmap: barrier access"

        let words = StyleWords(cyrillic: cyrillic)
        let tags = ["gate", "lift_gate", "swing_gate", "kissing_gate", "bollard",
                    "block", "cycle_barrier", "stile", "chain", "bus_trap"]
        let locked = words("barrier.locked")
        let noEntry = words("barrier.no-entry")
        let priv = words("barrier.private")

        var lines = ["", "", "\(marker) ----------------------------------------------",
                     "# Action-only: the barrier still falls through to the type rules below.",
                     ""]
        for tag in tags {
            let base = "${name|def:\(words("barrier.\(tag)"))}"
            lines.append("barrier=\(tag) & locked=yes { name '\(base) (\(locked))' }")
            lines.append("barrier=\(tag) & locked!=yes & access=no"
                         + " { name '\(base) (\(noEntry))' }")
            lines.append("barrier=\(tag) & locked!=yes & access!=no & foot=no"
                         + " { name '\(base) (\(noEntry))' }")
            lines.append("barrier=\(tag) & locked!=yes & access=private & foot!=yes"
                         + " { name '\(base) (\(priv))' }")
            lines.append("barrier=\(tag) { name '\(base)' }")
        }
        lines.append("")

        // Above the barrier type block, not at the end of the file: that block assigns a
        // type, so it consumes the barrier and nothing after it would ever be reached.
        switch try insertRules(lines.joined(separator: "\n") + "\n\n", marked: marker,
                               beforeLineWith: "# kmap: one rule per context, so each can"
                                   + " be hidden on its own.",
                               intoFile: "points", in: directory) {
        case .added:
            log.append("barriers named in the map's language, with access noted")
        case .missingAnchor:
            log.warn("the barrier block was not found — barrier access left unlabelled")
        case .leftAlone:
            break
        }
    }

    /// The barrier family in three groups, each on a number of its own: a borrowed
    /// style draws a boom and a bollard apart from a gate, and one number can carry
    /// only one of the three looks. Together they are mkgmap's own list, entire.
    static let barrierGroups: [(barriers: String, code: Int)] = [
        ("barrier=gate | barrier=swing_gate | barrier=kissing_gate | barrier=stile"
         + " | barrier=cycle_barrier", 0x3200),
        ("barrier=lift_gate", 0x3201),
        ("barrier=bollard | barrier=block | barrier=bus_trap", 0x3202),
    ]

    /// The kinds of way a barrier stands on, and nil for the rest. `kmap:on` is added
    /// by the annotate pass before the build: a node cannot otherwise know.
    static let barrierContexts: [String?] = ["path", "minor", "fence", nil]

    /// One barrier rule's condition line. The contexts stay mutually exclusive: a rule
    /// stripped of its type keeps its actions and continues, so an overlap would
    /// re-draw what a hide removed.
    static func barrierCondition(_ barriers: String, context: String?) -> String {
        context.map { "(\(barriers)) & kmap:on=\($0)" }
            ?? "(\(barriers)) & kmap:on!=path & kmap:on!=minor & kmap:on!=fence"
    }

    /// The action line under it: the barrier's kind as its name, and the number.
    static func barrierAction(code: Int) -> String {
        "    {add name='${barrier|subst:\"_=> \"}'} [0x\(String(code, radix: 16)) resolution 24]"
    }

    /// Splits mkgmap's one barrier rule by context, so each can be hidden on its own,
    /// and by group, so each wears its own number. The hide catalogue names these
    /// lines byte for byte, from the same definitions.
    func splitBarrierRule(in directory: URL, log: Log) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }

        let original = """
        barrier=bollard | barrier=bus_trap | barrier=gate | barrier=block | barrier=cycle_barrier |
            barrier=stile | barrier=kissing_gate | barrier=lift_gate | barrier=swing_gate
            {add name='${barrier|subst:"_=> "}'} [0x3200 resolution 24]
        """
        guard text.contains(original) else { return }

        var split = ["# kmap: one rule per context, so each can be hidden on its own,"
                     + " and one per group, so each wears its own number."]
        for context in Self.barrierContexts {
            for group in Self.barrierGroups {
                split.append(Self.barrierCondition(group.barriers, context: context))
                split.append(Self.barrierAction(code: group.code))
            }
        }
        text = text.replacingOccurrences(of: original, with: split.joined(separator: "\n"))
        try text.write(to: points, atomically: true, encoding: .utf8)
        log.append("barrier rule split by context and into gates, booms and bollards")
    }

    /// Makes a parking legible: its own name, in the map's language, and whether a car may
    /// be left there. The stock rule labels it in English, leaves a named parking without
    /// the access note, and draws the parking area unlabelled. Private ones stay dropped.
    func addParkingRules(in directory: URL, cyrillic: Bool,
                                 log: Log) throws {
        let marker = "# --- kmap: parking"

        let words = StyleWords(cyrillic: cyrillic)
        let services = words("parking.services")
        let parking = words("parking.parking")
        let entrance = words("parking.entrance")
        let customers = words("parking.customers")
        let permit = words("parking.permit")
        let fee = words("parking.fee")
        let layby = words("parking.layby")

        func named(_ condition: String, _ base: String, _ note: String) -> String {
            "\(condition) & name=* { name '${name} (\(note))' }\n"
            + "\(condition) & name!=* { name '\(base) (\(note))' }"
        }

        let rules = """


        \(marker) ---------------------------------------------
        # Action-only, and before the stock rule, which draws the icon. Its own
        # `add name=` is a no-op once a name exists, so these win.

        \(named("amenity=parking & access=customers", parking, customers))
        \(named("amenity=parking & access=permit", parking, permit))
        \(named("amenity=parking & fee=yes", parking, fee))
        amenity=parking & name!=* { name '\(parking)' }
        amenity=parking_entrance & name!=* { name '\(entrance)' }

        # mkgmap labels a motorway service complex with the English word "Services"
        # through `default_name`, which on a Russian map reads as machine text glued
        # to whatever the receiver draws for the exit. Naming it here instead means
        # the label follows the map's language like every other one.
        highway=services & name!=* { name '\(services)' }

        # A layby at a pass is where you leave the car, and OSM marks a good many of them
        # with a bare node. Neither the stock style nor ours had a rule for that: there is
        # one for `highway=rest_area` as an area, none for the node, so three of them within
        # 80 m of the Angarsky pass drew nothing while other maps show them. mkgmap's own
        # area rule types a rest area as a parking lot and says so in a comment; this
        # follows it, on the parking icon.
        highway=rest_area & name=* { name '${name}' } [0x2f0b resolution 24]
        highway=rest_area & name!=* { name '\(layby)' } [0x2f0b resolution 24]

        """

        guard try prependRules(rules + "\n", marked: marker, toFile: "points", in: directory)
        else { return }
        log.append("parking labelled in the map's own language")
    }

    func addAerialwayRules(in directory: URL, cyrillic: Bool, log: Log) throws {
        guard try spliceRules(Self.aerialwayLineRules(cyrillic: cyrillic),
                              marked: "# --- kmap: aerialways",
                              intoFile: "lines", in: directory) else { return }
        log.append("aerialways drawn: cable cars, chair lifts, drag lifts")
    }

    /// The link the road-end repair draws where something stands between the two ends.
    /// Written to the top of the file rather than before `<finalize>`, as other rules are.
    func addRepairLinkRule(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: repair links"
        let rule = """
        \(marker) -----------------------------------------------
        # A link this build put in where OSM left a gap no route could get past, and
        # something -- a kerb, a bank, an open channel, a drop -- stands between the two
        # ends. Written by the repair pass in Sources/kmap/OSM, which tags it
        # kmap:repair with what was crossed. A building or a fence is never crossed at
        # all, so no link is ever drawn over one.
        #
        # It has to sit at the TOP of the file rather than be spliced in above
        # <finalize> like the rest of kmap's rules. The link also carries highway=path,
        # so that the access and speed rules in <finalize> still apply to it -- and the
        # stock path rule further down would otherwise claim it first and draw it as an
        # ordinary trail, which is exactly what this is not.
        #
        # 0x0d is free in mkgmap's own style and in the vendor TYPs checked, and it is
        # inside the routable range: an extended type would draw beautifully and carry
        # no route, which is the whole point of the repair.
        kmap:repair=* [0x0d road_class=0 road_speed=0 resolution 22]


        """
        guard try prependRules(rule, marked: marker, toFile: "lines", in: directory)
        else { return }

        // The link and its mark appear together: a mark with no link under it reads as a
        // warning about nothing, and the link is what says the gap was closed. The mark is
        // the same size at every zoom and sits on no way, so routes are unchanged.
        try prependRules("""
            \(marker) ---------------------------------------------
            # The warning triangle on a repair link -- see the `lines` file for what one is.
            # At the same zoom as the link: the two belong together, and a triangle beside
            # a road with no link drawn under it says nothing a reader can act on.
            kmap:repair=* [0x660b resolution 22]


            """, marked: marker, toFile: "points", in: directory)
        log.append("repair links drawn as 0x0d, marked with 0x660b")
    }
}

/// Rule order that matters only under a borrowed look.
extension StyleCatalog {
    /// Puts the bus-stop rule above the platform rule.
    ///
    /// mkgmap draws both with one code, so their order never mattered to it. A borrowed
    /// style may draw them apart — a bus stop and a railway station are not the same
    /// sign — and a modern OSM bus stop carries `public_transport=platform` beside
    /// `highway=bus_stop`. Whichever rule stands first wins, so the specific one goes
    /// first and a bus stop stays a bus stop.
    func busStopsBeforePlatforms(in directory: URL, log: Log) throws {
        let url = directory.appendingPathComponent("points")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let stop = lines.firstIndex(where: {
            $0.hasPrefix("highway=bus_stop | railway=tram_stop [")
        }), let platform = lines.firstIndex(where: {
            $0.hasPrefix("public_transport=platform & (mkgmap:line2poi")
        }), platform < stop else { return }

        let rule = lines.remove(at: stop)
        lines.insert(rule, at: platform)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        log.append("bus stops read before platforms, so a borrowed look can tell them apart")
    }
}

/// Rules that follow a mark when the mark has to move.
extension StyleCatalog {
    /// Re-aims kmap's own repair rules onto the numbers its marks ended up on.
    ///
    /// The mark moves when a borrowed style already draws the number kmap repairs with;
    /// the rule emitting it must move too, or the links keep wearing the borrowed look.
    /// Only kmap's own rules are touched — they are the ones that name `kmap:repair`.
    @discardableResult
    static func moveRepairRules(_ moved: [MapElementKind: [Int: Int]],
                                in directory: URL) -> Int {
        var rewritten = 0
        for (kind, mapping) in moved {
            let url = directory.appendingPathComponent(kind.ruleFile)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            var at = 0
            while at < lines.count {
                defer { at += 1 }
                guard lines[at].contains("kmap:repair") else { continue }
                for (from, to) in mapping {
                    let old = String(format: "[0x%02x ", from)
                    guard lines[at].contains(old) else { continue }
                    let moved = lines[at].replacingOccurrences(
                        of: old, with: String(format: "[0x%02x ", to))
                    rewritten += 1
                    // A mark that carries no route just moves, and so does a link that
                    // found a number the receiver still routes on.
                    guard lines[at].contains("road_class="),
                          !TypAugment.routableLines.contains(to) else {
                        lines[at] = moved
                        continue
                    }
                    // Only the plain road numbers route, and the borrowed style has
                    // taken every one. The link keeps the number it can route on —
                    // wearing that style's look — and the dashes are drawn over it as a
                    // second line of their own, the way a style draws a casing.
                    lines[at] = lines[at].contains(" continue")
                        ? lines[at]
                        : lines[at].replacingOccurrences(of: "]", with: " continue]")
                    var paint = moved
                    for attribute in ["road_class", "road_speed"] {
                        while let mark = paint.range(of: "\(attribute)=[0-9]+",
                                                    options: .regularExpression) {
                            paint.removeSubrange(mark)
                        }
                    }
                    while paint.contains("  ") {
                        paint = paint.replacingOccurrences(of: "  ", with: " ")
                    }
                    paint = paint.replacingOccurrences(of: " ]", with: "]")
                    lines.insert(paint, at: at + 1)
                    at += 1
                }
            }
            guard rewritten > 0 else { continue }
            text = lines.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return rewritten
    }
}
