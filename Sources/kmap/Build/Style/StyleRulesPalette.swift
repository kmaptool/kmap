import Foundation

/// What the chosen palette can actually show.
///
/// kmap's rules are dense on purpose and draw more than any one palette paints. A number
/// the palette leaves blank is not a look — the receiver falls back on its own drawing,
/// which belongs to neither map — so the rule is made to draw nothing instead.
///
/// A rule that closes its chain keeps its condition and loses its type, taking an action
/// that removes the tag it matched on: deleted outright, the object would fall through
/// and be drawn as something else. A `continue` layer keeps its actions and loses only
/// its type. Routing is never touched.
extension StyleCatalog {

    /// Numbers kmap manufactures rather than draws from OSM: contours, sea, background
    /// and the land beneath. They are the ground the map stands on and answer to the
    /// build, not to a palette.
    private static let paletteExempt: [MapElementKind: Set<Int>] = [
        .line: [0x20, 0x21, 0x22],
        .polygon: [0x27, 0x32, 0x4a, 0x4b],
    ]

    /// Silences every rule the palette cannot paint, and says how many. Rules, not
    /// lines: mkgmap writes a long condition over two, and half a rule opens nothing.
    ///
    /// - Parameter chosen: numbers a person aimed a rule at by hand. Never silenced —
    ///   an unpainted number is exactly where someone goes on to draw one.
    @discardableResult
    static func keepOnlyWhatThePaletteDraws(in directory: URL, palette: TypSource,
                                            chosen: [MapElementKind: Set<Int>] = [:],
                                            log: Log) throws -> Int {
        var quieted = 0
        for kind in MapElementKind.allCases {
            let url = directory.appendingPathComponent(kind.ruleFile)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let painted = palette.codes(kind)
                .union(palette.deliberatelyUnstyled[kind] ?? [])
            guard !painted.isEmpty else { continue }

            var out: [String] = []
            var pending: [String] = []
            for line in text.components(separatedBy: "\n") {
                guard let code = emittedCode(of: line, kind: kind) else {
                    // A comment or a blank line between rules belongs to the file, not
                    // to the rule being gathered.
                    if line.trimmingCharacters(in: .whitespaces).isEmpty
                        || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        out.append(contentsOf: pending)
                        pending.removeAll()
                        out.append(line)
                    } else {
                        pending.append(line)
                    }
                    continue
                }
                let rule = pending + [line]
                pending.removeAll()
                if painted.contains(code) || paletteExempt[kind]?.contains(code) == true
                    || chosen[kind]?.contains(code) == true
                    || rule.contains(where: { $0.contains("road_class=") }) {
                    out.append(contentsOf: rule)
                    continue
                }
                if line.contains(" continue") {
                    // Its type goes, its actions stay: `set kmap:zone_edge=yes` is how a
                    // reserve gets its hatch, and dropping the line took the hatch with
                    // it. A layer that only draws goes altogether.
                    quieted += 1
                    if let open = line.range(of: "[0x") {
                        let head = String(line[line.startIndex..<open.lowerBound])
                        if rule.contains(where: { $0.contains("{") }) {
                            out.append(contentsOf: rule.dropLast())
                            out.append(head.trimmingTrailing())
                        }
                    }
                    continue
                }
                guard let quiet = quietened(rule, routable: kind == .line) else {
                    out.append(contentsOf: rule)
                    continue
                }
                out.append(contentsOf: quiet)
                quieted += 1
            }
            out.append(contentsOf: pending)
            try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        if quieted > 0 {
            log.append("\(quieted) rule(s) draw nothing — this palette paints no picture"
                       + " for the number they emit")
        }
        return quieted
    }

    /// The number a rule line emits, in the form a TYP names it: a point's subtype is
    /// folded into its number, the other kinds are the number itself.
    static func emittedCode(of line: String, kind: MapElementKind) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let open = trimmed.range(of: "[0x") else { return nil }
        let digits = trimmed[open.upperBound...].prefix { $0.isHexDigit }
        guard let code = Int(digits, radix: 16) else { return nil }
        return kind == .point && code < 0x100 ? code << 8 : code
    }

    /// The rule with its type taken away and `delete` put in its place, so the object
    /// stops here instead of being drawn as something else below. nil where no key can
    /// be removed safely. Alternatives about one key — `parking=underground |
    /// parking=multi-storey` — count, except among lines, where a removed `highway`
    /// would take another rule's routing with it.
    private static func quietened(_ rule: [String], routable: Bool) -> [String]? {
        guard let last = rule.last, let open = last.range(of: "[0x") else { return nil }
        let head = String(last[last.startIndex..<open.lowerBound])
        let whole = (rule.joined(separator: " ")).components(separatedBy: "[0x").first ?? ""
        let keys = Set(whole.allMatches("[a-z_:]+=").map { String($0.dropLast()) })
        guard !keys.isEmpty, keys.count <= 3,
              !whole.contains("!="), !whole.contains("~"),
              !whole.contains("|") || (keys.count == 1 && !routable) else {
            return nil
        }
        let removals = keys.sorted().map { "delete \($0)" }.joined(separator: "; ")
        // An action block already there takes the removals; otherwise one is opened.
        if let brace = head.lastIndex(of: "}") {
            var line = String(head[head.startIndex..<brace])
            line += "; " + removals + "}"
            return Array(rule[0..<(rule.count - 1)]) + [line.trimmingTrailing()]
        }
        return Array(rule[0..<(rule.count - 1)])
            + [head.trimmingTrailing() + " {" + removals + "}"]
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var out = self
        while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        return out
    }
}
