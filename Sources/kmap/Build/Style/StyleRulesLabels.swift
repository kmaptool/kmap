import Foundation

/// Rules about what the map says and which icon it says it with: peak labels, climbing
/// and volcano icons, the operator dropped from a label that has a name, translated
/// defaults, addresses and descriptions. Several turn on the target's code page.
extension StyleCatalog {
    /// Corrections to icon bindings, applied as prefix replacements so a trailing comment
    /// and either resolution survive. The prison, conference centre and convention centre
    /// cases live in redirects.txt instead, which is applied after this pass.
    private static let iconRepairs: [(String, String, String)] = [
        // (what, old prefix, new prefix)
        ("telephone off the wifi fan", "amenity=telephone [0x2f12 ", "amenity=telephone [0x2f18 "),
        ("emergency phone off the wifi fan", "amenity=emergency_phone [0x2f12 ", "amenity=emergency_phone [0x2f16 "),
        ("memorial off the museum", "historic=memorial [0x2c02 ", "historic=memorial [0x2c12 "),
        ("recycling off the pillar box", "amenity=recycling [0x2f15 ", "amenity=recycling [0x661a "),
        ("taxi off the bus", "amenity=taxi [0x2f17 ", "amenity=taxi [0x2f19 "),
        ("charging off the fuel pump", "amenity=charging_station [0x2f01 ", "amenity=charging_station [0x2f1a "),
        ("ferry to the anchor", "amenity=ferry_terminal [0x2f08 ", "amenity=ferry_terminal [0x2f09 "),
        ("arts centre to the mask", "amenity=arts_centre [0x2c04 ", "amenity=arts_centre [0x2d01 "),
        ("furniture to the plain shop", "shop=furniture [0x2e09 ", "shop=furniture [0x2e0c "),
        ("boat shop to the plain shop", "shop=boat [0x2f09 ", "shop=boat [0x2e0c "),
    ]

    /// Rules with no stock counterpart, inserted whole: no mkgmap rule mentions
    /// `aerialway=station` or `emergency=phone`, and the stock SOS rule knows only the
    /// deprecated `amenity=emergency_phone` spelling. Written in the map's own language;
    /// the English emergency wording matches mkgmap's own, so `translateDefaultNames`
    /// knows it either way.
    private static func liftStationRules(cyrillic: Bool) -> String {
        let words = StyleWords(cyrillic: cyrillic)
        let station = words("aerialway.station")
        let phone = words("sos.phone")
        return """


    # --- kmap: aerial lift stations ------------------------------------
    aerialway=station & name!=* { name '\(station)' } [0x2f1b resolution 22]
    aerialway=station { name '${name}' } [0x2f1b resolution 22]

    # --- kmap: the modern emergency-phone tag, same badge as the stock rule
    emergency=phone [0x2f16 resolution 22 default_name '\(phone)']
    """
    }

    /// Labels a summit with its name and its height in metres; the stock mkgmap `points`
    /// file uses feet and runs the two together. Split into four cases — both, either alone,
    /// neither — so none leaves a stray space; the first rule to match takes the point.
    func patchPeakLabel(in directory: URL, cyrillic: Bool, log: Log) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }
        var changed = false

        let imperial = "${ele|height:m=>ft|def:}"
        if text.contains(imperial) {
            text = text.replacingOccurrences(of: imperial, with: "${ele|def:}")
            log.append("summit heights relabelled in metres")
            changed = true
        }

        if let split = StyleCatalog.volcanoRules(in: text) {
            text = split
            log.append("the volcano badge reserved for active volcanoes")
            changed = true
        }

        if let climbing = StyleCatalog.climbingRules(in: text, cyrillic: cyrillic) {
            text = climbing
            log.append("the climber badge on crags, routes and climbing gyms")
            changed = true
        }

        let repaired = StyleCatalog.repairIcons(in: text, cyrillic: cyrillic)
        if repaired.text != text {
            text = repaired.text
            log.append("\(repaired.applied) icon binding(s) repaired, lift stations added")
            changed = true
        }
        for miss in repaired.missed {
            log.warn("icon repair did not match this mkgmap's style — \(miss)")
        }

        let merged = "natural=peak {name '${name|def:}${ele|def:}'} [0x6616 resolution 24]"
        if text.contains(merged) {
            let split = [
                "natural=peak & name=* & ele=* {name '${name} ${ele}'} [0x6616 resolution 24]",
                "natural=peak & name=* {name '${name}'} [0x6616 resolution 24]",
                "natural=peak & ele=* {name '${ele}'} [0x6616 resolution 24]",
                "natural=peak [0x6616 resolution 24]"
            ].joined(separator: "\n")
            text = text.replacingOccurrences(of: merged, with: split)
            log.append("summit labels split so the name and the height do not run together")
            changed = true
        }

        guard changed else { return }
        try text.write(to: points, atomically: true, encoding: .utf8)
    }

    static func repairIcons(in text: String, cyrillic: Bool)
        -> (text: String, applied: Int, missed: [String]) {
        var out = text
        var applied = 0
        var missed: [String] = []
        for (what, old, new) in iconRepairs {
            if out.contains(old) {
                out = out.replacingOccurrences(of: old, with: new)
                applied += 1
            } else if out.contains(new) {
                applied += 1        // already repaired on a previous pass
            } else {
                missed.append(what)
            }
        }
        if !out.contains("aerialway=station") {
            // The points file ends with a <finalize> section, and a typed rule inside it
            // is a style error that fails the compile.
            if let finalize = out.range(of: "<finalize>") {
                out.replaceSubrange(finalize.lowerBound..<finalize.lowerBound,
                                    with: liftStationRules(cyrillic: cyrillic) + "\n\n")
            } else {
                out += liftStationRules(cyrillic: cyrillic)
            }
            applied += 1
        }
        return (out, applied, missed)
    }

    static func climbingRules(in text: String, cyrillic: Bool) -> String? {
        let words = StyleWords(cyrillic: cyrillic)
        let gym = words("climbing.gym")
        let climbing = words("climbing.climbing")
        let crags = words("climbing.crags")
        let route = words("climbing.route")
        var out = text
        var changed = false
        for resolution in [22, 24] {
            let centre = "leisure=sports_center | leisure=sports_centre "
                + "{name '${name} (${sport})' | '${sport}'} [0x2d0a resolution \(resolution)]"
            guard out.contains(centre) else { continue }
            let spot = resolution == 24 ? 24 : 22
            let routeAt = 24
            let rules = [
                "# kmap: the climber badge, ahead of the sports centre -- see climbingRules",
                "sport=climbing & leisure=sports_centre & name!=* { name '\(gym)' } [0x2c0e resolution \(spot)]",
                "sport=climbing & name!=* { name '\(climbing)' } [0x2c0e resolution \(spot)]",
                "sport=climbing { name '${name}' } [0x2c0e resolution \(spot)]",
                "climbing=crag & name!=* { name '\(crags)' } [0x2c0e resolution \(spot)]",
                "climbing=crag { name '${name}' } [0x2c0e resolution \(spot)]",
                "(climbing=area | climbing=boulder | climbing=yes) & name!=* { name '\(climbing)' } [0x2c0e resolution \(spot)]",
                "(climbing=area | climbing=boulder | climbing=yes) { name '${name}' } [0x2c0e resolution \(spot)]",
                "(climbing=route | climbing=route_bottom) & name!=* { name '\(route)' } [0x2c0e resolution \(routeAt)]",
                "(climbing=route | climbing=route_bottom) { name '${name}' } [0x2c0e resolution \(routeAt)]",
                centre,
            ].joined(separator: "\n")
            out = out.replacingOccurrences(of: centre, with: rules)
            changed = true
        }
        return changed ? out : nil
    }

    static func volcanoRules(in text: String) -> String? {
        var out = text
        var changed = false
        for resolution in [22, 24] {
            let plain = "natural=volcano [0x2c0c resolution \(resolution)]"
            guard out.contains(plain) else { continue }
            let split = [
                "natural=volcano & volcano:status=active [0x2c0c resolution \(resolution)]",
                "natural=volcano & name=* & ele=* {name '${name} ${ele}'} [0x6616 resolution \(resolution)]",
                "natural=volcano & name=* {name '${name}'} [0x6616 resolution \(resolution)]",
                "natural=volcano & ele=* {name '${ele}'} [0x6616 resolution \(resolution)]",
                "natural=volcano [0x6616 resolution \(resolution)]"
            ].joined(separator: "\n")
            out = out.replacingOccurrences(of: plain, with: split)
            changed = true
        }
        return changed ? out : nil
    }

    /// Lets a feature mapped as an outline get an icon: mkgmap runs the `points` rules over
    /// nodes only. Keeps the point `--add-pois-to-areas` drops in a venue, discards it for
    /// `leisure` and `man_made` and for a venue the annotate pass marked as a duplicate.
    func addAreaPOIFilter(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: icons for things mapped as an outline"
        let rules = """
        \(marker) ------------------------
        # See addAreaPOIFilter. Must stay first: it works by leaving nothing behind.

        mkgmap:area2poi=true & kmap:dup_venue=yes { deletealltags }
        mkgmap:area2poi=true & amenity!=* & shop!=* & tourism!=* & office!=* \
        & healthcare!=* { deletealltags }


        """
        guard try prependRules(rules, marked: marker, toFile: "points", in: directory)
        else { return }
        log.append("outlined venues given their icons")
    }

    /// Keeps the operator out of a label that already has a name. `inc/name` folds
    /// `operator` into the label, where for a named object it adds nothing and costs width.
    /// Deleted only in that case: an unnamed object still falls back to its operator.
    func dropOperatorFromNamedLabels(in directory: URL, log: Log) throws {
        let include = directory.appendingPathComponent("inc/name")
        guard var text = try? String(contentsOf: include, encoding: .utf8) else { return }
        let marker = "# kmap: an object with a name of its own does not need its operator too"
        guard !text.contains(marker) else { return }
        let anchor = "brand=${name}     { delete brand; }"
        guard text.contains(anchor) else {
            log.warn("inc/name has changed in this mkgmap — operator left in labels")
            return
        }
        text = text.replacingOccurrences(
            of: anchor,
            with: anchor + "\n\n" + marker + "\nname=* { delete operator; }")
        try text.write(to: include, atomically: true, encoding: .utf8)
        log.append("operator dropped from labels that already carry a name")
    }

    /// Translates the mkgmap `default_name` labels, the label an object gets when OSM gives
    /// it none. Only the explicit `default_name` strings are touched; labels the stock
    /// fallbacks build out of a raw tag value are left in English.
    func translateDefaultNames(in directory: URL, cyrillic: Bool, log: Log) throws {
        guard cyrillic else { return }
        // mkgmap's own wording on the left, from Assets/default-names-ru.txt: these
        // captions have no OSM name behind them, so there is nothing else to translate.
        var words: [String: String] = [:]
        for raw in StyleAssets.defaultNameTranslations
            .split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let bar = line.firstIndex(of: "|") else { continue }
            words[String(line[line.startIndex..<bar])] = String(line[line.index(after: bar)...])
        }
        var changed: [String] = []
        for file in ["points", "lines", "polygons"] {
            let url = directory.appendingPathComponent(file)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var touched = false
            for (english, russian) in words {
                let from = "default_name '\(english)'"
                guard text.contains(from) else { continue }
                text = text.replacingOccurrences(of: from, with: "default_name '\(russian)'")
                touched = true
                changed.append(english)
            }
            if touched { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        if !changed.isEmpty {
            log.append("default labels translated: \(changed.count) of \(words.count)")
        }
    }

    /// Names the things OSM leaves unnamed, in Russian. The rules are action-only and go
    /// first; mkgmap keeps the first `name` that runs, so the stock mop-up that captions an
    /// object with its raw tag value finds a label already set. Cyrillic builds only.
    func addRussianLabels(in directory: URL, cyrillic: Bool, log: Log) throws {
        guard cyrillic else { return }
        var rules: [String] = []
        for raw in StyleAssets.russianLabels.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let bar = line.firstIndex(of: "|") else { continue }
            let pair = String(line[line.startIndex..<bar])
            let label = String(line[line.index(after: bar)...])
            guard !pair.isEmpty, !label.isEmpty else { continue }
            // A tag value may carry a semicolon, which the style parser reads as a statement
            // separator; quoting is what tells it otherwise, and unquoted the style fails.
            var condition = pair
            if let eq = pair.firstIndex(of: "="), pair[pair.index(after: eq)...].contains(";") {
                condition = String(pair[pair.startIndex..<eq]) + "='"
                          + String(pair[pair.index(after: eq)...]) + "'"
            }
            rules.append("\(condition) & name!=* { name '\(label)' }")
        }
        guard !rules.isEmpty else { return }

        let marker = "# --- kmap: names for things OSM leaves unnamed"
        let block = marker + " ---------------------------\n"
            + "# Generated from Assets/labels-ru.txt; see addRussianLabels. Action-only and\n"
            + "# first, so the stock mop-up rules cannot get in with a raw tag value.\n\n"
            + rules.joined(separator: "\n") + "\n\n\n"
        for file in ["points", "polygons", "lines"] {
            try prependRules(block, marked: marker, toFile: file, in: directory)
        }
        log.append("\(rules.count) Russian labels for unnamed objects")
    }

    /// Types what a walking map needs and the stock style drops: `ford`, every shelter but
    /// `shelter_type=basic_hut`, `mountain_pass` and `natural=saddle`. Each rule supplies a
    /// default name, since almost none of these objects carry one.
    func addTerrainPOIRules(in directory: URL, cyrillic: Bool,
                                    log: Log) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }
        let marker = "# --- kmap: terrain POIs"
        guard !text.contains(marker) else { return }

        // Almost none of these are named, so the default name carries the kind, and the
        // bracket carries it for the few that do have one.
        let words = StyleWords(cyrillic: cyrillic)
        let ford = words("terrain.ford")
        let stones = words("terrain.stones")
        let pass = words("terrain.pass")

        // Two icons: something enclosed to sit a storm out inside, against a roof on posts.
        let shelter = words("terrain.shelter")
        let hut = words("terrain.hut")
        let rock = words("terrain.rock-shelter")
        let leanTo = words("terrain.lean-to")
        let gazebo = words("terrain.gazebo")
        let picnic = words("terrain.picnic-shelter")
        let sun = words("terrain.sun-shelter")

        /// Named objects keep their name and gain the kind; unnamed ones become the kind.
        func named(_ condition: String, keep: String, alone: String,
                   type: String) -> String {
            "\(condition) & name=* { name '${name} (\(keep))' } [\(type) resolution 24]\n"
            + "\(condition) & name!=* { name '\(alone)' } [\(type) resolution 24]"
        }

        let rules = """


        \(marker) -----------------------------------------------
        # Objects the stock rule set never types at all.

        \(named("ford=stepping_stones", keep: stones, alone: "\(ford) (\(stones))",
                 type: "0x6514"))
        ford=yes | ford=stream { name '${name|def:\(ford)}' } [0x6514 resolution 24]

        mountain_pass=yes | natural=saddle { name '${name|def:\(pass)}' } [0x6613 resolution 24]

        # A bus shelter is a bus stop; a changing cabin is not shelter from anything.
        amenity=shelter & shelter_type=public_transport { delete amenity }
        amenity=shelter & shelter_type=changing_rooms { delete amenity }

        # Enclosed: somewhere to wait out weather.
        \(named("amenity=shelter & shelter_type=basic_hut", keep: hut.lowercased(),
                 alone: hut, type: "0x2b06"))
        \(named("amenity=shelter & shelter_type=weather_shelter", keep: shelter.lowercased(),
                 alone: shelter, type: "0x2b06"))
        \(named("amenity=shelter & shelter_type=rock_shelter", keep: rock,
                 alone: "\(shelter) (\(rock))", type: "0x2b06"))

        # A roof on posts.
        \(named("amenity=shelter & shelter_type=lean_to", keep: leanTo, alone: picnic,
                 type: "0x2b05"))
        \(named("amenity=shelter & shelter_type=gazebo", keep: gazebo.lowercased(),
                 alone: gazebo, type: "0x2b05"))
        \(named("amenity=shelter & (shelter_type=picnic_shelter"
                 + " | shelter_type=picnic_shelters | shelter_type=roof)",
                 keep: leanTo, alone: picnic, type: "0x2b05"))
        \(named("amenity=shelter & shelter_type=sun_shelter", keep: leanTo, alone: sun,
                 type: "0x2b05"))

        # Kind not recorded — 290 of them, so it needs to say something.
        amenity=shelter { name '${name|def:\(shelter)}' } [0x2b06 resolution 24]

        """

        splice(rules, into: &text)
        try text.write(to: points, atomically: true, encoding: .utf8)
        log.append("fords, shelters and mountain passes typed")
    }

    /// Makes address search work outside the countries `inc/address` hard-codes, by turning
    /// the `mkgmap:admin_level4…10` tags `--bounds` supplies into a city. Placed last, in
    /// the `<finalize>` section: actions are legal there and an explicit country still wins.
    func addGenericAddressRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: generic address fallback"
        let rules = """


        \(marker) ------------------------------------
        # Derive the city and region from the boundary data for countries mkgmap has no
        # specific rule for. Each guard is `!=*`, so anything already set is left alone,
        # and the admin_level tags only exist when --bounds is supplied — without it these
        # are simply no-ops. Level 8 is the municipality nearly everywhere; 9 and 10 are
        # sub-districts, 7 and 6 the larger units to fall back on.

        mkgmap:city!=* & mkgmap:admin_level8=* { set mkgmap:city='${mkgmap:admin_level8}' }
        mkgmap:city!=* & mkgmap:admin_level9=* { set mkgmap:city='${mkgmap:admin_level9}' }
        mkgmap:city!=* & mkgmap:admin_level10=* { set mkgmap:city='${mkgmap:admin_level10}' }
        mkgmap:city!=* & mkgmap:admin_level7=* { set mkgmap:city='${mkgmap:admin_level7}' }
        mkgmap:city!=* & mkgmap:admin_level6=* { set mkgmap:city='${mkgmap:admin_level6}' }

        mkgmap:region!=* & mkgmap:admin_level4=* { set mkgmap:region='${mkgmap:admin_level4}' }
        mkgmap:region!=* & mkgmap:admin_level5=* { set mkgmap:region='${mkgmap:admin_level5}' }

        """

        var patched = 0
        for name in ["points", "lines", "polygons"] {
            try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
                text += rules
                patched += 1
                return true
            }
        }
        log.append("generic address fallback added (\(patched) rule file(s))")
    }

    /// Carries OSM `description` into the object card. The format has no free-text field,
    /// so the text rides in an address field, which is shown only when an object is opened.
    /// Preference is `description:ru`, `description`, `description:en`, each excluding the
    /// others.
    func addDescriptionRules(in directory: URL,
                                     carrier: BuildRecipe.DescriptionCarrier,
                                     log: Log) throws {
        guard carrier != .off else { return }
        let marker = "# --- kmap: descriptions"

        let rules: String
        if let tag = carrier.tag {
            rules = """


            \(marker) -------------------------------------------------
            # OSM description text, carried into the object's card on the device.
            # Address fields never draw on the map, which is the point of using one.

            description:ru=* { set \(tag)='${description:ru}' }
            description=* & description:ru!=* { set \(tag)='${description}' }
            description:en=* & description:ru!=* & description!=* { set \(tag)='${description:en}' }

            """
        } else {
            // Appended to the label instead of an address field: an address block exists
            // only on POIs, so this carrier reaches ways and areas, but is drawn on the map.
            rules = """


            \(marker) -------------------------------------------------
            # OSM description text, appended to the object's own label in brackets.

            name=* & description:ru=* { name '${name} (${description:ru})' }
            name=* & description=* & description:ru!=* { name '${name} (${description})' }
            name=* & description:en=* & description:ru!=* & description!=* \
            { name '${name} (${description:en})' }

            """
        }

        // Action-only rules with no type fall through to the rules below, annotating the
        // element rather than consuming it, and must come first to do so.
        var patched = 0
        for name in ["points", "lines", "polygons"] {
            if try prependRules(rules + "\n", marked: marker, toFile: name, in: directory) {
                patched += 1
            }
        }
        log.append("descriptions carried in \(carrier.tag ?? "the name")"
                   + " (\(patched) rule file(s))")
    }
}
