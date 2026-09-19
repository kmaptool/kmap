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
        ("boat shop to the plain shop", "shop=boat [0x2f09 ", "shop=boat [0x2e0c ")
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
    /// file uses feet and runs the two together. Split into four cases - both, either alone,
    /// neither - so none leaves a stray space; the first rule to match takes the point.
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

    static func repairIcons(
        in text: String,
        cyrillic: Bool
    )
        -> (text: String, applied: Int, missed: [String])
    {
        var out = text
        var applied = 0
        var missed: [String] = []
        for (what, old, new) in iconRepairs {
            if out.contains(old) {
                out = out.replacingOccurrences(of: old, with: new)
                applied += 1
            } else if out.contains(new) {
                applied += 1  // already repaired on a previous pass
            } else {
                missed.append(what)
            }
        }
        if !out.contains("aerialway=station") {
            // The points file ends with a <finalize> section, and a typed rule inside it
            // is a style error that fails the compile.
            if let finalize = out.range(of: "<finalize>") {
                out.replaceSubrange(
                    finalize.lowerBound..<finalize.lowerBound,
                    with: liftStationRules(cyrillic: cyrillic) + "\n\n"
                )
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
            let centre =
                "leisure=sports_center | leisure=sports_centre "
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
                centre
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
            with: anchor + "\n\n" + marker + "\nname=* { delete operator; }"
        )
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
            .split(separator: "\n", omittingEmptySubsequences: true)
        {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                let bar = line.firstIndex(of: "|")
            else { continue }
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
                let bar = line.firstIndex(of: "|")
            else { continue }
            let pair = String(line[line.startIndex..<bar])
            let label = String(line[line.index(after: bar)...])
            guard !pair.isEmpty, !label.isEmpty else { continue }
            // A tag value may carry a semicolon, which the style parser reads as a statement
            // separator; quoting is what tells it otherwise, and unquoted the style fails.
            var condition = pair
            if let eq = pair.firstIndex(of: "="), pair[pair.index(after: eq)...].contains(";") {
                condition =
                    String(pair[pair.startIndex..<eq]) + "='"
                    + String(pair[pair.index(after: eq)...]) + "'"
            }
            rules.append("\(condition) & name!=* { name '\(label)' }")
        }
        guard !rules.isEmpty else { return }

        let marker = "# --- kmap: names for things OSM leaves unnamed"
        let block =
            marker + " ---------------------------\n"
            + "# Generated from Assets/labels-ru.txt; see addRussianLabels. Action-only and\n"
            + "# first, so the stock mop-up rules cannot get in with a raw tag value.\n\n"
            + rules.joined(separator: "\n") + "\n\n\n"
        for file in ["points", "polygons", "lines"] {
            try prependRules(block, marked: marker, toFile: file, in: directory)
        }
        log.append("\(rules.count) Russian labels for unnamed objects")
    }
}
