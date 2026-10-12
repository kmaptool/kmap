import Foundation

extension StylePort {
    /// The road hierarchy kept in the widths: a motorway drawn at every zoom takes a
    /// width the overview can carry, and without this the driveway beside it - drawn
    /// only up close - comes out the wider of the two.
    static func ordered(
        _ ported: [Ported],
        ranks: [Int: Int],
        theirs: TypSource?
    ) -> [Ported] {
        guard let theirs, !ranks.isEmpty else { return ported }
        var narrowest = Int.max
        var capped: [Int: Int] = [:]
        let roads = ported.filter { $0.kind == .line && ranks[$0.ours] != nil }
        // Rank by rank down the hierarchy, and a whole rank at a time: the classes
        // within one rank are the same road to a driver, so they take one width between
        // them rather than each capping the next.
        for rank in Set(roads.compactMap { ranks[$0.ours] }).sorted(by: >) {
            let here = roads.filter { ranks[$0.ours] == rank }
            let widths = here.compactMap {
                $0.width ?? theirs.section(.line, $0.theirs)?.lineWidth
            }
            guard let width = widths.min() else { continue }
            narrowest = min(narrowest, width)
            for port in here { capped[port.ours] = narrowest }
        }
        return ported.map { port in
            guard let width = capped[port.ours], port.kind == .line, width != port.width
            else { return port }
            // A copy, not a rebuild: the rivals and weight that settled the number stay.
            var capped = port
            capped.width = width
            return capped
        }
    }
}
