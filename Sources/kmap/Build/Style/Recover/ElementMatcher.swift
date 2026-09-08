import Foundation

/// Names the OSM way a map element was compiled from — or refuses.
///
/// Identification, not similarity: a candidate qualifies only by an aligned run of grid
/// cells, at least `minimumRun` consecutive vertices identical to the way's and covering
/// half the element. Below that, or with two candidates standing, the element is dropped.
enum ElementMatcher {
    static let minimumRun = 4

    /// The single way this vertex chain belongs to, or nil. Generic over the chain, so the
    /// caller can pass a slice of one large array rather than an array per element.
    static func way<Chain: RandomAccessCollection>(of cells: Chain,
                                                   in index: GroundIndex,
                                                   ring: Bool = false) -> Int32?
    where Chain.Element == UInt64, Chain.Index == Int {
        let grams = GarminGrid.grams(of: cells)
        guard !grams.isEmpty else { return nil }

        // Votes first: cheap, and almost always leaves one name standing. Both directions,
        // as the run check is, since mkgmap writes a way whichever way round suits it.
        var votes: [Int32: Int] = [:]
        for gram in grams {
            for pair in index.slots(of: gram) {
                votes[pair.slot, default: 0] += 1
            }
        }
        for gram in GarminGrid.gramsReversed(of: cells) {
            for pair in index.slots(of: gram) {
                votes[pair.slot, default: 0] += 1
            }
        }
        // Applied to every serious candidate, not only the top voter: two overlapping
        // ways can split the vote between them.
        let wanted = threshold(cells.count, ring: ring)
        let floor = ring ? max(1, min(grams.count / 4, wanted))
                         : max(1, grams.count / 4)
        var qualified: Int32 = -1
        for (slot, votes) in votes where votes >= floor {
            guard longestRun(of: cells, in: index.ways[Int(slot)].cells) >= wanted else {
                continue
            }
            // Two names standing is no name at all, and the second one settles it.
            guard qualified < 0 else { return nil }
            qualified = slot
        }
        return qualified < 0 ? nil : qualified
    }

    /// A line is one way and must mostly BE that way. A ring is different: a large fill
    /// is assembled from many member ways — a reserve is drawn as one polygon over dozens
    /// of boundary pieces — so any one member covers only a stretch of it. A ring
    /// therefore qualifies on a long aligned run alone, and the tags reach it because a
    /// member way inherits its relation's tags in the ground index. Ambiguity still
    /// refuses: a ring tracing two ways at once names neither.
    static func threshold(_ elementLength: Int, ring: Bool = false) -> Int {
        ring ? max(minimumRun * 2, min(elementLength / 2, 32))
             : max(minimumRun, elementLength / 2)
    }

    /// The longest aligned run of identical cells, in either direction — mkgmap writes
    /// a way whichever way round suits it.
    static func longestRun<Chain: RandomAccessCollection>(of element: Chain,
                                                          in way: [UInt64]) -> Int
    where Chain.Element == UInt64, Chain.Index == Int {
        guard !element.isEmpty, !way.isEmpty else { return 0 }
        // Where each of the way's cells sits, built once and read for both directions.
        var at: [UInt64: [Int32]] = [:]
        at.reserveCapacity(way.count)
        for (i, cell) in way.enumerated() { at[cell, default: []].append(Int32(i)) }
        return max(run(element, forward: true, at, way),
                   run(element, forward: false, at, way))
    }

    private static func run<Chain: RandomAccessCollection>(
        _ element: Chain, forward: Bool,
        _ at: [UInt64: [Int32]], _ way: [UInt64]) -> Int
    where Chain.Element == UInt64, Chain.Index == Int {
        let n = element.count
        let base = element.startIndex
        func cell(_ i: Int) -> UInt64 { element[base + (forward ? i : n - 1 - i)] }
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
            i += max(1, longestHere)
        }
        return best
    }
}
