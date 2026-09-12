import Foundation

/// Builds the catalogue of things kmap can leave off the map, from the rule lines of the
/// style it will actually be applied to.
///
/// A hide is an exact-line substitution, so the catalogue and the style must agree line
/// for line. The rules are therefore read at the point in materialization where a hide is
/// applied: before the POI zoom shift rewrites `resolution 24`, and before the labels are
/// translated.
enum HideableGenerator {
    /// The keys worth offering to hide, in the order the catalogue presents them.
    static let categories: [(key: String, name: String)] = [
        ("barrier", "Barriers and gates"),
        ("amenity", "Amenities"),
        ("shop", "Shops"),
        ("tourism", "Tourism"),
        ("leisure", "Leisure and sport"),
        ("highway", "Road features"),
        ("railway", "Railway"),
        ("natural", "Natural features"),
        ("man_made", "Man-made"),
        ("historic", "Historic"),
        ("emergency", "Emergency"),
        ("military", "Military"),
        ("power", "Power"),
        ("aeroway", "Aviation"),
        ("waterway", "Waterways"),
        ("office", "Offices"),
        ("craft", "Craft"),
        ("landuse", "Land use"),
    ]

    /// Keys never offered, since hiding them would empty the map.
    static let protectedKeys: Set<String> = ["place"]

    struct Result {
        var text: String
        var features: Int
        var keys: Int
    }

    /// One rule of the form `key=value ... [0x...]`, as far as this cares.
    struct Rule {
        let key: String
        let value: String
        let line: String
    }

    /// Reads one line of a points file, or nil where it is not a rule that can be offered:
    /// the line must be `key=value`, carry a `[0x...]` type, and set no tags.
    static func rule(from raw: String) -> Rule? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        // A condition continued on the next line cannot be removed on its own.
        guard !line.hasSuffix("|") else { return nil }

        var at = line.startIndex
        func take(while allowed: (Character) -> Bool) -> String {
            let from = at
            while at < line.endIndex, allowed(line[at]) { at = line.index(after: at) }
            return String(line[from..<at])
        }
        let key = take { $0.isLowercase && $0.isASCII || $0.isNumber || $0 == "_" || $0 == ":" }
        guard let first = key.first, first.isLetter, first.isLowercase else { return nil }
        _ = take { $0 == " " }
        guard at < line.endIndex, line[at] == "=" else { return nil }
        at = line.index(after: at)
        _ = take { $0 == " " }
        let value = take {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ":"
                           || $0 == "." || $0 == "-")
        }
        guard !value.isEmpty else { return nil }

        let rest = String(line[at...])
        guard let type = rest.range(of: "[0x") else { return nil }
        // Everything between the condition and the type: the actions.
        let middle = String(rest[rest.startIndex..<type.lowerBound])
        guard !middle.contains("{set "), !middle.contains("{add mkgmap:") else { return nil }
        // `[0x` has to be followed by at least one hex digit to be a type.
        let after = rest[type.upperBound...]
        guard let digit = after.first, digit.isHexDigit else { return nil }

        return Rule(key: key, value: value, line: raw.trimmingCharacters(in: .whitespaces))
    }

    /// `picnic_site` -> `Picnic site`.
    static func humanised(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    /// The identifier a hide is named by on the command line and in a profile.
    static func identifier(key: String, value: String) -> String {
        "\(key)-\(value.replacingOccurrences(of: ":", with: "-"))"
    }

    static func catalogue(fromPoints text: String) -> Result {
        // Insertion order, as the file has them: two rules for the same key and value are
        // both listed, in the order they are applied.
        var order: [String] = []
        var byPair: [String: [String]] = [:]
        var keysSeen: Set<String> = []
        let known = Set(categories.map(\.key))

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let rule = rule(from: String(raw)) else { continue }
            guard !protectedKeys.contains(rule.key), known.contains(rule.key) else { continue }
            let pair = rule.key + "\u{0}" + rule.value
            if byPair[pair] == nil { order.append(pair); byPair[pair] = [] }
            byPair[pair]?.append(rule.line)
            keysSeen.insert(rule.key)
        }

        var lines = [
            "# What kmap can leave off the map. Generated by kmap from the rule lines in",
            "# its own materialized points file, so every substitution is exact.",
            "#",
            "# Hiding removes a rule, not data: rebuild without the box ticked and it is back.",
            "# Format:  @@ <category>   then  [id] <name>   then 'tag: key=value'   then one",
            "# 'points: <exact line>' per rule the entry covers.",
            "#",
            "# The quoted 'points:' lines are mkgmap's own, from its default style, and are",
            "# GPL v2 like the rest of it. They are here because a substitution has to name",
            "# the line it replaces exactly. See NOTICE.md.",
            "",
        ]

        var count = 0
        for (key, category) in categories {
            let group = order.filter { $0.hasPrefix(key + "\u{0}") }
            guard !group.isEmpty else { continue }
            lines.append("@@ \(category)")
            // By value, compared byte for byte so the order does not depend on a locale.
            for pair in group.sorted(by: { valueOf($0).utf8.lexicographicallyPrecedes(valueOf($1).utf8) }) {
                let value = valueOf(pair)
                lines.append("[\(identifier(key: key, value: value))] \(humanised(value))")
                // The OSM tag this entry stands for, so the same choice can be applied to
                // the custom-POI file as well as to the map.
                lines.append("tag: \(key)=\(value)")
                for rule in byPair[pair] ?? [] { lines.append("points: \(rule)") }
                count += 1
            }
            lines.append("")
        }
        return Result(text: lines.joined(separator: "\n") + "\n",
                      features: count, keys: keysSeen.count)
    }

    private static func valueOf(_ pair: String) -> String {
        String(pair.split(separator: "\u{0}", maxSplits: 1).last ?? "")
    }
}
