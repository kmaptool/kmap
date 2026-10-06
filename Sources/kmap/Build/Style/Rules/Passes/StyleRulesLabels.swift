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

    /// A sport is labelled with its OSM value, written as words: "table tennis, billiards",
    /// not "table_tennis;billiards". On a map labelled in Cyrillic a value the iD editor's
    /// community translation names is said in Russian; others stay as OSM has them.
    func labelSportValues(in directory: URL, cyrillic: Bool, log: Log) throws {
        let marker = "# --- kmap: sport values in words"
        var rules: [String] = []
        if cyrillic {
            for raw in StyleAssets.russianSports.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let bar = line.firstIndex(of: "|") else { continue }
                rules.append("sport=\(line[..<bar]) { set kmap:sport='\(line[line.index(after: bar)...])' }")
            }
        }
        rules.append("sport=* & kmap:sport!=* { set kmap:sport='\(Self.spelledSport)' }")
        let block =
            marker + " ---------------------------\n"
            + "# Action-only and first: the labels below read kmap:sport. Russian names from\n"
            + "# the iD editor's preset schema (ISC); see Assets/sport-ru.txt.\n\n"
            + rules.joined(separator: "\n") + "\n\n\n"
        var changed = 0
        for file in ["points", "polygons", "lines"] {
            let url = directory.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("${sport}") else { continue }
            try FileTools.write(Data(text.replacingOccurrences(of: "${sport}", with: "${kmap:sport}").utf8), to: url)
            try prependRules(block, marked: marker, toFile: file, in: directory)
            changed += 1
        }
        if changed > 0 { log.append("sport values said in words in \(changed) rule file(s)") }
    }

    /// The OSM value with its underscores and semicolons spelled, by mkgmap's own filter.
    static let spelledSport = "${sport|subst:\"_=> \"|subst:\";=>, \"}"

    /// The stock rules put an "Internet(wlan)" point over every hotel and cafe that has it.
    /// Written as 1 line per kind instead, so each can be hidden, and wireless as "Wi-Fi":
    /// the hide catalogue offers only single-line rules.
    func splitInternetAccess(in directory: URL, log: Log) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }
        let yes = "internet_access=yes {name 'Internet ${name}' | 'Internet'} [0x2f12 resolution 24 continue]"
        let rest = "internet_access=* & internet_access!=no & internet_access!=yes\n"
        guard text.contains(yes), text.contains(rest) else { return }
        let wireless = ["wlan", "wifi"].map {
            "internet_access=\($0) {name 'Wi-Fi ${name}' | 'Wi-Fi'} [0x2f12 resolution 24 continue]"
        }
        text = text.replacingOccurrences(of: yes, with: (wireless + [yes]).joined(separator: "\n"))
        text = text.replacingOccurrences(
            of: rest,
            with: "internet_access=* & internet_access!=no & internet_access!=yes & internet_access!=wlan"
                + " & internet_access!=wifi\n"
        )
        try FileTools.write(Data(text.utf8), to: points)
        log.append("internet access drawn as Wi-Fi where it is, 1 hideable rule per kind")
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
        try FileTools.write(text, to: points)
    }

    static func repairIcons(
        in text: String,
        cyrillic: Bool
    ) -> (text: String, applied: Int, missed: [String]) {
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
        try FileTools.write(text, to: include)
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
            if touched { try FileTools.write(text, to: url) }
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
        var rules: [(condition: String, label: String)] = []
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
            rules.append((condition, label))
        }
        guard !rules.isEmpty else { return }

        let marker = "# --- kmap: names for things OSM leaves unnamed"
        for file in ["points", "polygons", "lines"] {
            // A parking or a school fenced round carries barrier=fence too: on an area the
            // word would name the fence, not the place.
            let fitting = file == "polygons" ? rules.filter { !$0.condition.hasPrefix("barrier=") } : rules
            let lines = fitting.flatMap { rule -> [String] in
                // A fenced school's area makes a point too: the word would name the fence.
                var rule = rule
                if file == "points" && rule.condition.hasPrefix("barrier=") {
                    rule.condition += " & mkgmap:area2poi!=true"
                }
                // A ref that starts with the word is the label alone: "Pier 3", not "Pier Pier
                // 3". mkgmap r4924 reads `!~` as `!` and `~`, so the negation is spelled out.
                let other = "!(ref ~ '(?iuU)\(Self.literal(rule.label))\\b.*')"
                let word = "'${ref}' | '\(rule.label)'"
                // Only with nothing else to say, where the stock naming says it: a brand, an
                // operator or a ref first, "Lukoil" saying more than "fuel". A number with
                // no name says little alone: "9" becomes "Pier 9".
                var out = [
                    "\(rule.condition) & name!=* & brand!=* & operator!=* & ref=* & \(other) { name '\(rule.label) ${ref}' }",
                    "\(rule.condition) & name!=* & brand!=* & operator!=* { name \(word) }"
                ]
                // mkgmap runs a closed way through the lines rules too, ahead of the areas'
                // naming. An open line has no naming from a brand or an operator, and there
                // the stock mop-up would write the raw tag value instead. A barrier has no
                // area naming, so it takes its word closed or not.
                if file == "lines" {
                    let open = rule.condition.hasPrefix("barrier=") ? "" : " & is_closed()=false"
                    out += [
                        "\(rule.condition) & name!=*\(open) & ref=* & \(other) { name '\(rule.label) ${ref}' }",
                        "\(rule.condition) & name!=*\(open) { name \(word) }"
                    ]
                }
                return out
            }
            let block =
                marker + " ---------------------------\n"
                + "# Generated from Assets/labels-ru.txt; see addRussianLabels. Action-only and\n"
                + "# first, so the stock mop-up rules cannot get in with a raw tag value.\n\n"
                + lines.joined(separator: "\n") + "\n\n\n"
            try prependRules(block, marked: marker, toFile: file, in: directory)
        }
        log.append("\(rules.count) Russian labels for unnamed objects")
    }

    /// `text` as a Java pattern matching itself: anything but a letter, a digit, a space
    /// or a hyphen goes in brackets.
    static func literal(_ text: String) -> String {
        text.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? String($0) : "[\($0)]" }.joined()
    }
}
