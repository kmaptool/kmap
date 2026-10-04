import Foundation

/// What the split plan is made of: the plan itself, and the interned tile sets it
/// stores its answers in without holding one Set per node.
extension TileSplitter {
    struct Plan {
        /// Extra tiles for a node, beyond the one it sits in. A flat sorted table of
        /// interned pairs, read by binary search from every worker at once.
        var extra = ExtraTiles()
        /// The sets themselves, held once each. See `TileSets`.
        var sets = TileSets()
        /// Which set of tiles a way that spans tiles, or is carried by a relation, needs.
        var wayTiles: [Int64: Int32] = [:]
        /// The same for every relation worth writing.
        var relationTiles: [Int64: Int32] = [:]
    }

    /// Tile sets held once each and named by number, so a caller compares and stores an
    /// Int32 rather than a set of tiles.
    struct TileSets {
        /// Sorted, so a caller that wants them in order does not sort again. Number 0 is
        /// the empty set, which is what a way nothing was planned for answers with.
        private var pool: [[UInt16]] = [[]]
        private var index: [Set<UInt16>: Int32] = [:]

        mutating func intern(_ tiles: Set<UInt16>) -> Int32 {
            if tiles.isEmpty { return 0 }
            if let known = index[tiles] { return known }
            let made = Int32(pool.count)
            pool.append(tiles.sorted())
            index[tiles] = made
            return made
        }

        subscript(_ at: Int32) -> [UInt16] { pool[Int(at)] }

        /// How many distinct sets there are.
        var count: Int { pool.count }

        /// Drops the interning table, which is wanted only while the plan is built; the
        /// sets themselves are read all through the write pass.
        mutating func sealed() { index = [:] }
    }

    /// The nodes that must reach tiles beyond their own, and which tiles: built by
    /// appending, settled by one sort, read by binary search. See `Plan.extra`.
    struct ExtraTiles {
        private var pairs: [(id: Int64, set: Int32)] = []
        /// Where each already-sorted stretch of `pairs` begins. A lane sorts its own
        /// harvest before handing it over; `settle` merges the stretches.
        private var runStarts: [Int] = []
        private var ids: [Int64] = []
        private var setAt: [Int32] = []
        private var pool: [[UInt16]] = []
        private var poolIndex: [Set<UInt16>: Int32] = [:]
        private var settled = false
        /// The pool once settled, end to end, set `i` at `poolStart[i] ..< poolStart[i + 1]`:
        /// read by every worker at once, and a range into it is handed out rather than
        /// an array, whose reference count all of them would contend for.
        private(set) var poolTiles: [UInt16] = []
        private var poolStart: [Int32] = [0]

        var isEmpty: Bool { ids.isEmpty && pairs.isEmpty }

        /// One tile set held once, however many nodes point at it.
        mutating func intern(_ tiles: Set<UInt16>) -> Int32 {
            if let hit = poolIndex[tiles] { return hit }
            let index = Int32(pool.count)
            pool.append(tiles.sorted())
            poolIndex[tiles] = index
            return index
        }

        mutating func note(_ node: Int64, set index: Int32) {
            pairs.append((node, index))
        }

        /// Reserves room for pairs about to arrive, once; growing the array would hold
        /// two copies of it at the same moment.
        mutating func reserve(pairs count: Int) {
            pairs.reserveCapacity(pairs.count + count)
        }

        /// Folds in a worker's harvest: its pool is interned here once per distinct set
        /// and its pairs re-pointed and appended. The order the pairs arrive in does not
        /// matter, since `settle` sorts them and the unions it takes are commutative.
        mutating func absorb(
            pool otherPool: [[UInt16]],
            pairs otherPairs: [(id: Int64, set: Int32)],
            sorted: Bool = false
        ) {
            var remap = [Int32](repeating: 0, count: otherPool.count)
            for (at, tiles) in otherPool.enumerated() {
                remap[at] = intern(Set(tiles))
            }
            // Re-pointing a pair leaves its id alone, so a sorted harvest is still
            // sorted when it lands here.
            if sorted { runStarts.append(pairs.count) }
            pairs.reserveCapacity(pairs.count + otherPairs.count)
            for pair in otherPairs {
                pairs.append((pair.id, remap[Int(pair.set)]))
            }
        }

        /// Orders the pairs, then unions the sets of any node that appears more than once
        /// into a fresh pool entry.
        mutating func settle() {
            guard !settled else { return }
            settled = true
            // Sorts the pairs themselves, not their indices, and by stretches, since each
            // lane's harvest arrives already sorted.
            order()
            ids.reserveCapacity(pairs.count)
            setAt.reserveCapacity(pairs.count)
            var at = 0
            while at < pairs.count {
                let id = pairs[at].id
                var index = pairs[at].set
                var next = at + 1
                while next < pairs.count, pairs[next].id == id {
                    let other = pairs[next].set
                    if other != index {
                        var union = Set(pool[Int(index)])
                        union.formUnion(pool[Int(other)])
                        index = intern(union)
                    }
                    next += 1
                }
                ids.append(id)
                setAt.append(index)
                at = next
            }
            pairs = []
            poolIndex = [:]
            runStarts = []
            for tiles in pool {
                poolTiles.append(contentsOf: tiles)
                poolStart.append(Int32(poolTiles.count))
            }
        }

        typealias Pair = (id: Int64, set: Int32)
        typealias Stretch = (from: Int, to: Int)

        /// Puts `pairs` in order of id, merging the stretches the lanes handed over
        /// sorted. Ties keep the earlier stretch first, as a stable sort would.
        private mutating func order() {
            var bounds = sortedStretches()
            guard bounds.count > 1 else { return }
            var source = pairs
            // `pairs` gives up its storage: holding a second reference would make the
            // first write through the buffer pointer below copy all of it.
            pairs = []
            var target = [Pair](repeating: (0, 0), count: source.count)
            while bounds.count > 1 {
                let plan = bounds
                source.withUnsafeMutableBufferPointer { from in
                    target.withUnsafeMutableBufferPointer { into in
                        bounds = Self.mergeRound(plan, from: UnsafeBufferPointer(from), into: into)
                    }
                }
                swap(&source, &target)
            }
            pairs = source
        }

        /// The sorted stretches of `pairs`, the first sorted here when no lane handed it over.
        private mutating func sortedStretches() -> [Stretch] {
            var bounds: [Stretch] = []
            let firstRun = runStarts.first ?? pairs.count
            if firstRun > 0 {
                pairs[0..<firstRun].sort { $0.id < $1.id }
                bounds.append((0, firstRun))
            }
            for (at, start) in runStarts.enumerated() {
                bounds.append((start, at + 1 < runStarts.count ? runStarts[at + 1] : pairs.count))
            }
            bounds.removeAll { $0.from >= $0.to }
            return bounds
        }

        /// Merges each neighbouring pair of stretches, side by side, and returns the
        /// stretches left. An odd stretch at the end is copied across unmerged.
        private static func mergeRound(
            _ plan: [Stretch],
            from: UnsafeBufferPointer<Pair>,
            into: UnsafeMutableBufferPointer<Pair>
        ) -> [Stretch] {
            let merges = plan.count / 2
            // Each merge reads and writes its own 2 stretches: nothing is shared.
            nonisolated(unsafe) let from = from, into = into
            DispatchQueue.concurrentPerform(iterations: merges) { k in
                merge(plan[2 * k], plan[2 * k + 1], from: from, into: into)
            }
            var next: [Stretch] = []
            for k in 0..<merges { next.append((plan[2 * k].from, plan[2 * k + 1].to)) }
            if plan.count % 2 == 1 {
                let last = plan[plan.count - 1]
                for at in last.from..<last.to { into[at] = from[at] }
                next.append(last)
            }
            return next
        }

        /// Merges 2 neighbouring stretches, the left one first on a tie.
        private static func merge(
            _ left: Stretch,
            _ right: Stretch,
            from: UnsafeBufferPointer<Pair>,
            into: UnsafeMutableBufferPointer<Pair>
        ) {
            var i = left.from, j = right.from, out = left.from
            while i < left.to, j < right.to {
                if from[j].id < from[i].id {
                    into[out] = from[j]; j += 1
                } else {
                    into[out] = from[i]; i += 1
                }
                out += 1
            }
            while i < left.to { into[out] = from[i]; i += 1; out += 1 }
            while j < right.to { into[out] = from[j]; j += 1; out += 1 }
        }

        /// Where in `poolTiles` the extra tiles for this node are, in order, or nil when it
        /// has none. Only once settled.
        /// - Parameter at: the caller's own cursor, walked forward for ascending queries;
        ///   a query that steps backwards falls back to a binary search.
        func tiles(for id: Int64, walking at: inout Int) -> Range<Int>? {
            let found: Int? = ids.withUnsafeBufferPointer { sorted -> Int? in
                // Most nodes have no extra tiles: the cursor already stands between the
                // ids below and above this one, and the answer is no without moving.
                if at <= sorted.count, at == 0 || sorted[at - 1] < id, at == sorted.count || sorted[at] > id {
                    return nil
                }
                if at < sorted.count, sorted[at] <= id {
                    var next = at
                    let limit = min(sorted.count, at + 64)
                    while next < limit, sorted[next] < id { next += 1 }
                    if next < limit {
                        at = next
                        return sorted[next] == id ? next : nil
                    }
                }
                // Behind the cursor, or too far ahead to walk to: binary search, and the
                // cursor resumes from there.
                var lo = 0, hi = sorted.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if sorted[mid] < id { lo = mid + 1 } else { hi = mid }
                }
                at = lo
                return lo < sorted.count && sorted[lo] == id ? lo : nil
            }
            return found.map {
                let set = Int(setAt[$0])
                return Int(poolStart[set])..<Int(poolStart[set + 1])
            }
        }
    }

    /// Ids wanted by a pass, sorted and walked in step with the file rather than hashed
    /// once per object. Both lists ascend, so it is a merge.
    struct WantedIDs {
        private let ids: [Int64]
        private var at = 0
        private var lastID = Int64.min

        init(_ wanted: Set<Int64>) {
            ids = wanted.sorted()
        }

        /// From ids already in order and unique.
        init(sorted: [Int64]) {
            ids = sorted
        }

        var isEmpty: Bool { ids.isEmpty }

        mutating func wants(_ id: Int64) -> Bool { rank(of: id) != nil }

        /// Where `id` stands among the wanted ids, or nil if it is not one of them.
        mutating func rank(of id: Int64) -> Int? {
            if id < lastID { at = 0 }  // a worker starting its own run of blocks
            lastID = id
            while at < ids.count, ids[at] < id { at += 1 }
            return at < ids.count && ids[at] == id ? at : nil
        }
    }
}
