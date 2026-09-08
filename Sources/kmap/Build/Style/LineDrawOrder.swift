import Foundation

/// Which line covers which, when two are drawn over the same ground.
///
/// A receiver paints the lines of one subdivision in the order the map stores them, and
/// mkgmap stores them in the order they happened to arrive — so a river could land on top
/// of the trunk road it passes under, and a driveway on top of the motorway it joins. The
/// order is given a rule instead: every type a road rule emits carries a rank, and the
/// patched mkgmap writes the ranked types in rank order (a stable sort, so everything
/// else keeps the order it had, water and rail and fences included, all below the roads).
///
/// The ranks are read from the style itself — whichever OSM tags a rule matches on decide
/// what the code it emits means — so a borrowed style, a shipped one and a recovered one
/// are all ordered by the same rule without knowing anything about their numbering.
enum LineDrawOrder {

    /// The importance of one `highway` value: what the road carries, not how it is drawn.
    /// A larger number is painted later, hence on top.
    private static let rankByHighway: [String: Int] = [
        "path": 1, "footway": 1, "cycleway": 1, "steps": 1, "bridleway": 1, "track": 1,
        "service": 2, "residential": 2, "living_street": 2, "pedestrian": 2,
        "unclassified": 2, "road": 2, "busway": 2,
        "tertiary": 3, "tertiary_link": 3,
        "secondary": 4, "secondary_link": 4,
        "primary": 5, "primary_link": 5,
        "trunk": 6, "trunk_link": 6,
        "motorway": 7, "motorway_link": 7,
    ]

    /// The rank of each line code the style's road rules emit, highest claim wins: one code
    /// is often reached by several rules, and the code is drawn the same whichever matched.
    static func ranks(in index: RuleSetIndex) -> [Int: Int] {
        var ranks: [Int: Int] = [:]
        for meaning in index.byKind[.line]?.values ?? [:].values {
            var best = 0
            for tag in meaning.tags {
                guard tag.hasPrefix("highway=") else { continue }
                best = max(best, rankByHighway[String(tag.dropFirst("highway=".count))] ?? 0)
            }
            if best > 0 { ranks[meaning.code] = best }
        }
        return ranks
    }

    /// The option the patched mkgmap reads, or nil when the style names no roads — an
    /// unranked map keeps mkgmap's own order, exactly as before.
    static func option(in index: RuleSetIndex) -> String? {
        let ranks = ranks(in: index)
        guard !ranks.isEmpty else { return nil }
        let list = ranks.sorted { $0.key < $1.key }
            .map { "\(TypeMeaning.hex($0.key)):\($0.value)" }
        return "--x-line-draw-order=" + list.joined(separator: ",")
    }
}
