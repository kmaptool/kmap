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
        mutating func absorb(pool otherPool: [[UInt16]], pairs otherPairs: [(id: Int64, set: Int32)],
                             sorted: Bool = false) {
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
        }

        /// Puts `pairs` in order of id, merging the stretches the lanes handed over
        /// sorted. Ties keep the earlier stretch first, as a stable sort would.
        private mutating func order() {
            var bounds: [(from: Int, to: Int)] = []
            let firstRun = runStarts.first ?? pairs.count
            if firstRun > 0 {
                pairs[0..<firstRun].sort { $0.id < $1.id }
                bounds.append((0, firstRun))
            }
            for (at, start) in runStarts.enumerated() {
                bounds.append((start, at + 1 < runStarts.count ? runStarts[at + 1] : pairs.count))
            }
            bounds.removeAll { $0.from >= $0.to }
            guard bounds.count > 1 else { return }

            var source = pairs
            // `pairs` gives up its storage: holding a second reference would make the
            // first write through the buffer pointer below copy all of it.
            pairs = []
            var target = [(id: Int64, set: Int32)](
                repeating: (0, 0), count: source.count)
            while bounds.count > 1 {
                let merges = bounds.count / 2
                let plan = bounds
                source.withUnsafeMutableBufferPointer { from in
                    target.withUnsafeMutableBufferPointer { into in
                        DispatchQueue.concurrentPerform(iterations: merges) { k in
                            let left = plan[2 * k], right = plan[2 * k + 1]
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
                    }
                }
                var next: [(from: Int, to: Int)] = []
                for k in 0..<merges { next.append((plan[2 * k].from, plan[2 * k + 1].to)) }
                // An odd stretch at the end is copied across unmerged.
                if plan.count % 2 == 1 {
                    let last = plan[plan.count - 1]
                    source.withUnsafeBufferPointer { from in
                        target.withUnsafeMutableBufferPointer { into in
                            for at in last.from..<last.to { into[at] = from[at] }
                        }
                    }
                    next.append(last)
                }
                swap(&source, &target)
                bounds = next
            }
            pairs = source
        }

        /// The extra tiles for this node, or nil when it has none.
        /// - Parameter at: the caller's own cursor, walked forward for ascending queries;
        ///   a query that steps backwards falls back to a binary search.
        func tiles(for id: Int64, walking at: inout Int) -> [UInt16]? {
            let found: Int? = ids.withUnsafeBufferPointer { sorted -> Int? in
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
            return found.map { pool[Int(setAt[$0])] }
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

        var isEmpty: Bool { ids.isEmpty }

        mutating func wants(_ id: Int64) -> Bool {
            if id < lastID { at = 0 }        // a worker starting its own run of blocks
            lastID = id
            while at < ids.count, ids[at] < id { at += 1 }
            return at < ids.count && ids[at] == id
        }
    }
}
