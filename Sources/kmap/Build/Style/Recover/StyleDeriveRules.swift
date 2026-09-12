import Foundation

/// Rule lines re-aimed: split by claimant, pinned to the zooms a code owns, closed
/// and banded.
extension StyleRecovery {
    /// Splits one rule into one rule per claiming code, each taking exactly the
    /// alternatives its code was seen drawing; alternatives no code was seen on stay
    /// with the strongest claimant. Only for a condition of the safe shape - a leading
    /// parenthesised group of bare pairs - and only when at least two codes own at
    /// least one alternative each; anything else returns nil and the rule is rewritten
    /// whole, as before.
    static func splitRule(
        _ line: DefaultRuleBook.Line,
        ranked: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])])
        -> [String]? {
        if line.leadingGroup() == nil, line.wildcardHead() != nil {
            return splitFamilyRule(line, ranked: ranked)
        }
        guard let (pairs, span) = line.leadingGroup() else { return nil }
        // Each alternative goes to the code with most witnesses for its tag.
        var owner: [String: Int] = [:]
        for pair in pairs {
            var bestType: Int?
            var bestCount = fewestWitnesses - 1
            for claim in ranked {
                if let count = claim.tags[pair], count > bestCount {
                    bestCount = count
                    bestType = claim.type
                }
            }
            if let bestType { owner[pair] = bestType }
        }
        var byOwner: [Int: [String]] = [:]
        for pair in pairs {
            byOwner[owner[pair] ?? ranked[0].type, default: []].append(pair)
        }
        guard byOwner.count > 1 else { return nil }
        var out = ["@@ \(line.file)", "- \(line.text)"]
        if let second = line.continuation { out.append("- \(second)") }
        // The strongest claimant goes last, keeping the file's reading order stable.
        for (type, taken) in byOwner.sorted(by: { ($0.value.count, $1.key)
                                                  < ($1.value.count, $0.key) }) {
            out.append(contentsOf: line.replacementSplitting(
                group: taken, span: span, to: type).map { "+ \($0)" })
        }
        return out
    }

    /// Splits a family rule - `shop=* & name=*` - by dedication: each claimant that
    /// leads concrete tags of the family gets a dedicated rule above it, and the
    /// family itself keeps the strongest claim for everything else. mkgmap reads top
    /// down, so the dedicated rules win exactly their own tags.
    private static func splitFamilyRule(
        _ line: DefaultRuleBook.Line,
        ranked: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])])
        -> [String]? {
        guard let base = ranked.first else { return nil }
        var dedicated: [(pair: String, type: Int)] = []
        for claim in ranked.dropFirst() {
            // The tags this code owns outright within the family's claims.
            for (tag, count) in claim.tags.sorted(by: { $0.key < $1.key })
            where count >= fewestOutright
                && !ranked.contains(where: { $0.type != claim.type
                    && ($0.tags[tag] ?? 0) > count }) {
                dedicated.append((tag, claim.type))
            }
        }
        guard !dedicated.isEmpty else { return nil }
        var out = ["@@ \(line.file)", "- \(line.text)"]
        if let second = line.continuation { out.append("- \(second)") }
        for (pair, type) in dedicated {
            out.append(contentsOf: line.replacementDedicating(pair: pair, to: type)
                .map { "+ \($0)" })
        }
        out.append(contentsOf: line.replacement(to: base.type).map { "+ \($0)" })
        return out
    }

    /// Keeps, for each code, only the zooms at which it draws this meaning more than
    /// any other code does - or at which it was painted over the same elements as the
    /// code that does, which makes the two layers of one drawing rather than rivals.
    /// A style whose plain road types are blank paints every road twice, once on the
    /// routable number and once on the stroke that shows: dropping the loser there
    /// would leave the road routable and invisible.
    ///
    /// A code left owning nothing is dropped: their map draws the meaning some other
    /// way there, and painting both would stack two looks.
    static func ownedZooms(
        _ byType: [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                         resolutions: [Int: Int])])
        -> [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])] {
        guard byType.count > 1 else { return byType }
        var owner: [Int: Int] = [:]      // zoom -> code
        var best: [Int: Int] = [:]       // zoom -> that code's count there
        // By type, so a tie goes the same way every run.
        for claim in byType.values.sorted(by: { $0.type < $1.type }) {
            for (zoom, count) in claim.resolutions where count > (best[zoom] ?? 0) {
                best[zoom] = count
                owner[zoom] = claim.type
            }
        }
        var out: [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                        resolutions: [Int: Int])] = [:]
        for (type, claim) in byType {
            let kept = claim.resolutions.filter { zoom, _ in
                guard owner[zoom] != type else { return true }
                guard let over = owner[zoom], let held = byType[over] else { return false }
                return paintsTheSame(claim.ids, held.ids)
            }
            guard !kept.isEmpty else { continue }
            out[type] = (claim.type, claim.weight, claim.ids, claim.tags, kept)
        }
        // A code with no zooms recorded at all - a point matched only at the detailed
        // level - keeps its claim: there is nothing to divide.
        return out.isEmpty ? byType : out
    }

    /// The strokes, then the rule that closes the chain.
    ///
    /// Order was tried the other way - the rule first, so the borrowed paint would lie
    /// on top - and it leaks: a stroke pinned to a band does not match outside it, so
    /// at those zooms the chain runs on into the rules below and picks up whatever they
    /// draw. The rule goes last, where it stops the search, as mkgmap's own rules do.
    static func keeping(_ rule: DefaultRuleBook.Line,
                                under strokes: [String]) -> [String] {
        keeping(rule.continuation.map { [rule.text, $0] } ?? [rule.text],
                under: strokes)
    }

    static func keeping(_ rule: [String], under strokes: [String]) -> [String] {
        (strokes + rule).map { "+ " + $0 }
    }

    /// The line that closes the chain, pinned to the zooms its own code owns.
    ///
    /// A ladder hands each zoom to one code, but the closing line keeps the rule's own
    /// `resolution N`, which means N and every zoom finer - so where a stroke owns the
    /// zoom, the base code draws underneath it as well. On a road that costs nothing,
    /// since their plain numbers are blank; on water, whose plain number is a drawn
    /// line, the two stack and the river comes out wider than the map it was learned
    /// from. Left alone where the line carries routing: a road is routed on its number
    /// at every zoom, whatever is drawn over it.
    ///
    /// The band never reaches past where the rule already drew: a code seen at a zoom
    /// the rule does not draw at says something about their map, not about ours.
    static func closing(_ lines: [String], of line: DefaultRuleBook.Line,
                                owning resolutions: [Int: Int],
                                under strokes: [String]) -> [String] {
        guard !strokes.isEmpty, !lines.isEmpty,
              !(line.text + (line.continuation ?? "")).contains("road_class="),
              var low = resolutions.keys.min(), let high = resolutions.keys.max()
        else { return lines }
        var out = lines
        let last = out.count - 1
        if let own = out[last].firstCapture("resolution ([0-9]+)").flatMap({ Int($0) }) {
            low = max(low, own)
        }
        guard low <= high else { return lines }
        out[last] = out[last].replacingOccurrences(
            of: "resolution [0-9-]+", with: "resolution \(low)-\(high)",
            options: .regularExpression)
        return out
    }

    /// One stroke of a rule's ladder: the rule's line re-aimed to `type` and pinned to
    /// the band of zooms that code was actually seen at. Without a band the stroke
    /// would also draw at every finer zoom, where another stroke of the same ladder
    /// belongs. A code with no recorded zooms keeps the rule's own resolution.
    static func banded(_ line: DefaultRuleBook.Line, to type: Int,
                               resolutions: [Int: Int]) -> String {
        let layered = line.layered(to: type)
        guard let low = resolutions.keys.min(),
              let high = resolutions.keys.max() else { return layered }
        return layered.replacingOccurrences(of: "resolution [0-9-]+",
                                            with: "resolution \(low)-\(high)",
                                            options: .regularExpression)
    }
}
