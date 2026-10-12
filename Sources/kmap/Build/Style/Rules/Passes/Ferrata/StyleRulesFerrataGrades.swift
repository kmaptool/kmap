import Foundation

/// A via ferrata routed as a path and drawn by its grade. Each grade is 2 rules: a road on
/// the path's number, which routes and wears the path's clear picture, then a plain line on
/// the grade's own number, which is seen and picked by the cursor. B to F have numbers of
/// their own; ungraded, 0 and A share 0x37.
extension StyleCatalog {
    /// OSM's `via_ferrata_scale` 2 to 6, the Alps' B to F, with a `+` or `-` allowed.
    static let ferrataGrades: [(scale: String, code: Int)] = [
        ("2", 0x39), ("3", 0x3a), ("4", 0x3b), ("5", 0x3c), ("6", 0x3d)
    ]

    /// In the condition of a via ferrata's road, which carries its own plain line: the road
    /// twins pass leaves it alone. Always true, as no way has the tag.
    static let ownTwin = "kmap:own_twin!=yes"

    /// The path's number, which a via ferrata's road takes.
    static let pathCode = 0x0e

    /// The road under a via ferrata: the path's number, on foot only whatever access OSM
    /// gives it, unpaved for a router told to avoid that.
    private static func ferrataRoad(_ condition: String, rung: Substring) -> String {
        "\(condition) & \(ownTwin) {add foot=yes; add access=no; set vehicle=no; set bicycle=no;"
            + " set motor_vehicle=no; set mkgmap:unpaved=1} [\(TypeMeaning.hex(pathCode)) road_class=0 road_speed=0 \(rung) continue]"
    }

    /// Put above the via ferrata's own rule, on its rung.
    func splitFerrataGrades(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: via ferrata grades"
        let url = directory.appendingPathComponent("lines")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.contains(marker) else { return }
        var lines = text.components(separatedBy: "\n")
        let head = "highway=via_ferrata [0x37 "
        guard let at = lines.firstIndex(where: { $0.hasPrefix(head) }),
            let close = lines[at].firstIndex(of: "]")
        else { return }
        let rung = lines[at][lines[at].index(lines[at].startIndex, offsetBy: head.count)..<close]
        var rules = [marker]
        for grade in Self.ferrataGrades {
            let condition = "highway=via_ferrata & via_ferrata_scale ~ '\(grade.scale)[+-]?'"
            rules.append(Self.ferrataRoad(condition, rung: rung))
            rules.append("\(condition) [\(TypeMeaning.hex(grade.code)) \(rung)]")
        }
        rules.append(Self.ferrataRoad("highway=via_ferrata", rung: rung))
        lines.insert(contentsOf: rules, at: at)
        try FileTools.write(lines.joined(separator: "\n"), to: url)
        log.append("via ferrata routed as a path and drawn by grade")
    }

    /// A via ferrata line the TYP paints no picture for goes, and the road above it is
    /// twinned as any path is. A number aimed at by hand is left as it is.
    ///
    /// - Parameters:
    ///   - painted: the line numbers the TYP paints.
    ///   - twinned: once the twins are made, the roads that have one. A via ferrata whose
    ///     road has none goes too: the road keeps its picture and would show under the line.
    static func drawFerrataAsPath(in directory: URL, painted: Set<Int>, twinned: Set<Int>? = nil) throws {
        let url = directory.appendingPathComponent("lines")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(ownTwin) else { return }
        let ours = Set([0x37] + ferrataGrades.map(\.code))
        var lines = text.components(separatedBy: "\n")
        var gone = IndexSet()
        for at in lines.indices.dropFirst() {
            let line = lines[at]
            guard line.hasPrefix("highway=via_ferrata"), !line.contains(RuleReassignment.mark),
                let code = plainCode(of: line), ours.contains(code), !painted.contains(code),
                lines[at - 1].contains(ownTwin)
            else { continue }
            if let twinned, let road = plainCode(of: lines[at - 1]), twinned.contains(road) { continue }
            gone.insert(at)
            // The plain line that ended the rule is gone: the road ends it now.
            lines[at - 1] = lines[at - 1].replacingOccurrences(of: " & " + ownTwin, with: "")
                .replacingOccurrences(of: " continue]", with: "]")
        }
        guard !gone.isEmpty else { return }
        let kept = lines.indices.filter { !gone.contains($0) }.map { lines[$0] }
        try FileTools.write(kept.joined(separator: "\n"), to: url)
    }

    /// The number a rule line emits, read from its `[0x..`.
    private static func plainCode(of line: String) -> Int? {
        guard let open = line.range(of: "[0x") else { return nil }
        let digits = line[open.upperBound...].prefix { $0.isHexDigit }
        return Int(digits, radix: 16)
    }
}
