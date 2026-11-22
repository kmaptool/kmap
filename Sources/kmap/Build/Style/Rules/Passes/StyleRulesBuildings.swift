import Foundation

/// A building another rule claims first.
///
/// The stock rules type an outline by its first match, and the building rule stands
/// near the end: a town hall is an amenity area, a bakery a shop, a castle a historic
/// site. A palette that leaves those areas clear loses the building with them. Such an
/// outline gets a layer of its own, on its own number, under the rule that claims it:
/// drawn only where a palette paints it, so every other style is as it was.
extension StyleCatalog {
    /// The number of that layer.
    static let claimedBuildingCode = 0x36
    static let claimedBuildingMarker = "# --- kmap: buildings another rule claims"
    /// Where the stock building rule starts, the last word in an outline's type.
    static let stockBuildingRule = "building=* & building!=no [0x13"

    func addClaimedBuildingLayer(in directory: URL, log: Log) throws {
        var missing = false
        try amendRuleFile("polygons", in: directory, unlessMarked: Self.claimedBuildingMarker) { text in
            guard let rule = Self.claimedBuildingRule(for: text) else {
                missing = true
                return false
            }
            text =
                "\(Self.claimedBuildingMarker) ---------------------\n"
                + "# A layer over the area the rule below draws: `continue`, so that rule still fires.\n"
                + rule + "\n\n\n" + text
            return true
        }
        if missing {
            log.warn("the stock building rule was not found - buildings another rule claims keep its look")
        } else {
            log.append("buildings another rule claims given a layer of their own")
        }
    }

    /// The keys the layer's rule of a rule set names: what claims a building there.
    /// Empty for a rule set without the layer.
    static func claimingKeys(inRules directory: URL) -> Set<String> {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("polygons"), encoding: .utf8),
            let rule = text.split(separator: "\n").first(where: {
                $0.hasPrefix("building=*") && $0.contains("[\(TypeMeaning.hex(claimedBuildingCode)) ")
            }), let open = rule.firstIndex(of: "(")
        else { return [] }
        return Set(String(rule[open...]).allMatches("[a-z_:]+=\\*").map { String($0.dropLast(2)) })
    }

    /// The layer's rule for a polygons file: a building carrying a key that a rule
    /// above the stock building rule draws by. nil where the file has no such rule.
    static func claimedBuildingRule(for polygons: String) -> String? {
        guard let stock = polygons.range(of: "\n" + stockBuildingRule) else { return nil }
        var keys: Set<String> = []
        for line in polygons[..<stock.lowerBound].split(separator: "\n") {
            guard !line.hasPrefix("#"), let type = line.range(of: "[0x"),
                !line[type.lowerBound...].contains(" continue")
            else { continue }
            let condition = line[..<type.lowerBound]
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[a-z_:]+!=[^ )]+", with: "", options: .regularExpression)
            let tested = condition.allMatches("[a-z_:]+[=~]").map { String($0.dropLast()) }
            // Alternatives each name a subject; otherwise the first term does, and
            // the rest narrow it.
            let subjects = condition.contains("&") ? Array(tested.prefix(1)) : tested
            keys.formUnion(subjects.filter { $0 != "building" && !$0.contains(":") })
        }
        guard !keys.isEmpty else { return nil }
        let any = keys.sorted().map { $0 + "=*" }.joined(separator: " | ")
        return "building=* & building!=no & (\(any))"
            + " [\(TypeMeaning.hex(claimedBuildingCode)) resolution 24 continue]"
    }
}
