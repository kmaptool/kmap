import Foundation

/// Names the OSM way a map element was compiled from, or refuses.
///
/// Identification, not similarity: a candidate qualifies by aligned cells, runs of at
/// least `minimumRun` consecutive vertices identical to the way's, together covering
/// half the element. Two candidates standing name it only when they mean one thing.
enum ElementMatcher {
    static let minimumRun = 4

    /// The element traces this share of a closed way's cells to count as tracing it whole.
    static let tracedWhole = 0.9

    /// A candidate needs one gram in this many before its runs are checked.
    static let checkedShare = 4

    /// The most aligned cells a ring is asked for: a large fill is assembled from many
    /// member ways, so no one member covers more than a stretch of it.
    static let ringRunCap = 32

    private struct Candidate {
        let slot: Int32
        let aligned: Int
        /// A closed way the element traces nearly all of: the polygon itself, not a
        /// neighbour sharing an edge.
        let whole: Bool
    }

    /// The single way this vertex chain belongs to, or nil. Generic over the chain, so the
    /// caller can pass a slice of one large array rather than an array per element.
    static func way<Chain: RandomAccessCollection>(of cells: Chain,
                                                   in index: GroundIndex,
                                                   ring: Bool = false) -> Int32?
    where Chain.Element == UInt64, Chain.Index == Int {
        let n = cells.count
        let first = cells.startIndex
        // A two-vertex element is one edge, looked up as such.
        let edge = n == GarminGrid.edgeVertices
        let grams = edge ? [GarminGrid.edge(cells[first], cells[first + 1])]
            : GarminGrid.grams(of: cells)
        guard !grams.isEmpty else { return nil }

        // Votes first: cheap, and almost always leaves one name standing. Both directions,
        // as the run check is, since mkgmap writes a way whichever way round suits it.
        var votes: [Int32: Int] = [:]
        for gram in grams {
            for pair in index.slots(of: gram) {
                votes[pair.slot, default: 0] += 1
            }
        }
        let reversed = edge ? [GarminGrid.edge(cells[first + 1], cells[first])]
            : GarminGrid.gramsReversed(of: cells)
        for gram in reversed {
            for pair in index.slots(of: gram) {
                votes[pair.slot, default: 0] += 1
            }
        }
        // Applied to every serious candidate, not only the top voter: two overlapping
        // ways can split the vote between them. Two grams is the shortest run that
        // counts, so every piece of a way split or merged since gets its check.
        let wanted = threshold(n, ring: ring)
        let least = min(minimumRun, n)
        let floor = max(1, min(grams.count / checkedShare, minimumRun - 2))
        var standing: [Candidate] = []
        var pieces: [Candidate] = []
        for (slot, votes) in votes where votes >= floor {
            let way = index.ways[Int(slot)].cells
            let closed = way.count >= GarminGrid.ringVertices && way.first == way.last
            // A ring may start anywhere along a closed way: walked twice round.
            let along = ring && closed ? way + way.dropFirst() : way
            let aligned = alignment(of: cells, in: along, least: least).aligned
            guard aligned >= least else { continue }
            let candidate = Candidate(
                slot: slot, aligned: aligned,
                whole: ring && closed && Double(aligned) >= tracedWhole * Double(way.count))
            if aligned >= wanted { standing.append(candidate) } else { pieces.append(candidate) }
        }
        if !standing.isEmpty { return settle(standing, length: n, in: index) }
        // Nothing holds it alone: the pieces of one thing, split or merged since the
        // map was made, if together they would.
        guard pieces.count > 1,
              pieces.reduce(0, { $0 + $1.aligned }) >= wanted else { return nil }
        return settle(pieces, length: n, in: index)
    }

    /// One name out of several candidates, or nil.
    private static func settle(_ candidates: [Candidate], length: Int,
                               in index: GroundIndex) -> Int32? {
        if candidates.count == 1 { return candidates[0].slot }
        if let one = agreed(candidates, in: index) { return one }
        // A closed way traced whole that is nearly the whole element is the element;
        // the rest are neighbours sharing an edge.
        let itself = candidates.filter {
            $0.whole && Double($0.aligned) >= tracedWhole * Double(length)
        }
        if itself.count == 1 { return itself[0].slot }
        // A hole in a multipolygon: mkgmap cuts the fill through it, so a piece traces
        // the hole's ring as well as the outer's. The hole is not what the fill means.
        let outer = candidates.filter { !index.isInner($0.slot) }
        guard !outer.isEmpty else { return nil }
        if outer.count < candidates.count {
            if outer.count == 1 { return outer[0].slot }
            if let one = agreed(outer, in: index) { return one }
        }
        let whole = outer.filter { $0.whole && $0.aligned * 2 >= length }
        return whole.count == 1 ? whole[0].slot : nil
    }

    /// The best of the candidates when all of them mean one thing, else nil.
    private static func agreed(_ candidates: [Candidate], in index: GroundIndex) -> Int32? {
        let meanings = Set(candidates.map {
            DefaultRuleBook.meaning(of: index.tags(ofWay: $0.slot))
        })
        guard meanings.count == 1 else { return nil }
        return candidates.max { ($0.aligned, $1.slot) < ($1.aligned, $0.slot) }?.slot
    }

    /// A line is one way and must mostly BE that way. A ring is different: a large fill
    /// is assembled from many member ways, a reserve is drawn as one polygon over dozens
    /// of boundary pieces, so any one member covers only a stretch of it. A ring
    /// therefore qualifies on a long aligned run alone, and the tags reach it because a
    /// member way inherits its relation's tags in the ground index. Ambiguity still
    /// refuses: a ring tracing two ways of different meaning names neither.
    /// An element shorter than `minimumRun` must align whole: a building is five
    /// vertices, a driveway two.
    static func threshold(_ elementLength: Int, ring: Bool = false) -> Int {
        let least = min(minimumRun, elementLength)
        return ring ? max(least, min(elementLength / 2, ringRunCap))
                    : max(least, elementLength / 2)
    }

    /// The longest aligned run of identical cells, in either direction: mkgmap writes
    /// a way whichever way round suits it.
    static func longestRun<Chain: RandomAccessCollection>(of element: Chain,
                                                          in way: [UInt64]) -> Int
    where Chain.Element == UInt64, Chain.Index == Int {
        alignment(of: element, in: way).longest
    }

    /// The element's cells lying in aligned runs of at least `least`, and the longest
    /// such run, in the better of the two directions. Runs rather than one run: a
    /// node moved since the map was made breaks the run, not the identity.
    static func alignment<Chain: RandomAccessCollection>(of element: Chain,
                                                         in way: [UInt64],
                                                         least: Int = minimumRun)
        -> (aligned: Int, longest: Int)
    where Chain.Element == UInt64, Chain.Index == Int {
        guard !element.isEmpty, !way.isEmpty else { return (0, 0) }
        // Where each of the way's cells sits, built once and read for both directions.
        var at: [UInt64: [Int32]] = [:]
        at.reserveCapacity(way.count)
        for (i, cell) in way.enumerated() { at[cell, default: []].append(Int32(i)) }
        let forward = runs(element, forward: true, at, way, least: least)
        let backward = runs(element, forward: false, at, way, least: least)
        return forward.aligned > backward.aligned
            || (forward.aligned == backward.aligned && forward.longest >= backward.longest)
            ? forward : backward
    }

    private static func runs<Chain: RandomAccessCollection>(
        _ element: Chain, forward: Bool,
        _ at: [UInt64: [Int32]], _ way: [UInt64], least: Int) -> (aligned: Int, longest: Int)
    where Chain.Element == UInt64, Chain.Index == Int {
        let n = element.count
        let base = element.startIndex
        func cell(_ i: Int) -> UInt64 { element[base + (forward ? i : n - 1 - i)] }
        var aligned = 0
        var best = 0
        var i = 0
        while i < n {
            // Every place this cell sits in the way is tried: nodes closer than the grid
            // step collapse into one cell, and the first run that grows may not be longest.
            var longestHere = 0
            for start in at[cell(i)] ?? [] {
                var runLength = 1
                while i + runLength < n, Int(start) + runLength < way.count,
                      cell(i + runLength) == way[Int(start) + runLength] {
                    runLength += 1
                }
                if runLength > longestHere { longestHere = runLength }
            }
            if longestHere > best { best = longestHere }
            if longestHere >= least { aligned += longestHere }
            i += max(1, longestHere)
        }
        return (aligned, best)
    }
}
