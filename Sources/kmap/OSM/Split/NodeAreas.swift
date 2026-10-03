import CVector
import Foundation

/// Which tile each node belongs to, for every node in the extract: ids and the area each
/// sits in, appended in file order and looked up by walking rather than by hashing.
extension TileSplitter {
    final class NodeAreas {
        static let outside = UInt16.max
        static let setFlag: UInt16 = 0x8000
        /// The node also falls in a neighbour's shape band, and the value indexes
        /// `bandSets` rather than `sets`.
        static let bandFlag: UInt16 = 0x4000
        static let flags: UInt16 = setFlag | bandFlag

        private(set) var sets: [[UInt16]] = []
        private var setIndex: [[UInt16]: UInt16] = [:]
        /// The same table keyed by the lookup's own answer, so a node on a border needs no
        /// array built for it.
        private var hitsIndex: [AreaLookup.Hits: UInt16] = [:]
        private var bandHitsIndex: [BandKey: UInt16] = [:]

        struct BandKey: Hashable {
            let strict: AreaLookup.Hits
            let shape: AreaLookup.Hits
        }

        /// The strict answer and the shape answer, in that order, for a node in a band.
        private(set) var bandSets: [(strict: [UInt16], shape: [UInt16])] = []
        private var bandIndex: [[UInt16]: UInt16] = [:]

        /// Set when a table ran out of names. A band set has 14 bits for its index, so
        /// 16384 of them; a plain set is read by its own flag first and has 15, less the
        /// one that would spell `outside`. A node past that is filed as outside, and the
        /// caller refuses the split rather than lose it.
        private(set) var overflowed = false
        private static let mostSets = Int(outside & ~setFlag)
        private static let mostBandSets = Int(bandFlag)

        /// The sets again, end to end, for the workers: a run is read in place rather than
        /// handed out as an array whose reference count they would all contend for. Set
        /// `i` is `setTiles[setStart[i] ..< setStart[i + 1]]`, and a band set's strict
        /// half the same in `bandTiles`. Read on many threads only once filled, hence the
        /// unchecked access, here and on the table below.
        @exclusivity(unchecked) private var setTiles: [UInt16] = []
        @exclusivity(unchecked) private var setStart: [Int32] = [0]
        @exclusivity(unchecked) private var bandTiles: [UInt16] = []
        @exclusivity(unchecked) private var bandStart: [Int32] = [0]

        private func noteSet(_ tiles: [UInt16]) {
            setTiles.append(contentsOf: tiles)
            setStart.append(Int32(setTiles.count))
        }

        private func noteBand(strict: [UInt16]) {
            bandTiles.append(contentsOf: strict)
            bandStart.append(Int32(bandTiles.count))
        }

        /// Appends the areas a stored value names, as `areas(of:)` gives them.
        func appendAreas(of value: UInt16, to out: inout [UInt16]) {
            if value == Self.outside { return }
            if value & Self.setFlag != 0 {
                let set = Int(value & ~Self.setFlag)
                for at in Int(setStart[set])..<Int(setStart[set + 1]) { out.append(setTiles[at]) }
            } else if value & Self.bandFlag != 0 {
                let band = Int(value & ~Self.bandFlag)
                for at in Int(bandStart[band])..<Int(bandStart[band + 1]) { out.append(bandTiles[at]) }
            } else {
                out.append(value)
            }
        }

        func intern(_ set: [UInt16]) -> UInt16 {
            let sorted = set.sorted()
            if let hit = setIndex[sorted] { return hit }
            guard sets.count < Self.mostSets else { overflowed = true; return Self.outside }
            let index = UInt16(sets.count) | Self.setFlag
            sets.append(sorted)
            noteSet(sorted)
            setIndex[sorted] = index
            return index
        }

        /// The same, from the answer as the lookup gave it: already in order, and
        /// allocating only when the set is a new one.
        func intern(_ hits: AreaLookup.Hits) -> UInt16 {
            if let hit = hitsIndex[hits] { return hit }
            guard sets.count < Self.mostSets else { overflowed = true; return Self.outside }
            let index = UInt16(sets.count) | Self.setFlag
            sets.append(hits.sorted)
            noteSet(hits.sorted)
            hitsIndex[hits] = index
            return index
        }

        /// A node whose shape answer is wider than its strict one. The pair is the
        /// identity, so both halves are interned together.
        func internBand(strict: AreaLookup.Hits, shape: AreaLookup.Hits) -> UInt16 {
            let key = BandKey(strict: strict, shape: shape)
            if let hit = bandHitsIndex[key] { return hit }
            guard bandSets.count < Self.mostBandSets else { overflowed = true; return Self.outside }
            let index = UInt16(bandSets.count) | Self.bandFlag
            bandSets.append((strict.sorted, shape.sorted))
            noteBand(strict: strict.sorted)
            bandHitsIndex[key] = index
            return index
        }

        func internBand(strict: [UInt16], shape: [UInt16]) -> UInt16 {
            let key = strict.sorted() + [UInt16.max] + shape.sorted()
            if let hit = bandIndex[key] { return hit }
            guard bandSets.count < Self.mostBandSets else { overflowed = true; return Self.outside }
            let index = UInt16(bandSets.count) | Self.bandFlag
            bandSets.append((strict.sorted(), shape.sorted()))
            noteBand(strict: strict.sorted())
            bandIndex[key] = index
            return index
        }

        /// The areas a stored value names: where the node itself lives.
        func areas(of value: UInt16) -> [UInt16] {
            if value == Self.outside { return [] }
            if value & Self.setFlag != 0 { return sets[Int(value & ~Self.setFlag)] }
            if value & Self.bandFlag != 0 { return bandSets[Int(value & ~Self.bandFlag)].strict }
            return [value]
        }

        /// The areas a shape through this node has to be delivered to: the strict answer
        /// widened by the neighbours whose band the node falls in. Only closed ways ask.
        func shapeAreas(of value: UInt16) -> [UInt16] {
            if value == Self.outside { return [] }
            if value & Self.setFlag != 0 { return sets[Int(value & ~Self.setFlag)] }
            if value & Self.bandFlag != 0 { return bandSets[Int(value & ~Self.bandFlag)].shape }
            return [value]
        }
        // Ids arrive ascending, as a PBF stores them, so they are appended and searched.
        // The order is not promised: a descending step opens a new run, each run stays
        // sorted on its own, and a lookup walks the runs.
        @exclusivity(unchecked) fileprivate var keys: [Int64] = []
        @exclusivity(unchecked) fileprivate var values: [UInt16] = []
        @exclusivity(unchecked) private var runs: [Int] = [0]
        private var lastKey = Int64.min
        var count: Int { keys.count }

        init(expecting: Int) {
            keys.reserveCapacity(expecting)
            values.reserveCapacity(expecting)
        }

        /// Where each input file's stretch of the table ends, and whether every stretch is
        /// strictly ascending; the write pass's merge dedup rests on both. Checked by
        /// scanning, not assumed: an unsorted file would make the merge silently wrong.
        private(set) var fileEnds: [Int] = []
        private(set) var filesInterleave = false

        /// Called once per input file, after its last block has been appended.
        func markFileEnd() {
            let start = fileEnds.last ?? 0
            if start < keys.count {
                var sorted = true
                keys.withUnsafeBufferPointer { k in
                    var i = start + 1
                    while i < k.count {
                        if k[i] <= k[i - 1] { sorted = false; break }
                        i += 1
                    }
                }
                if !sorted { filesInterleave = true }
            }
            fileEnds.append(keys.count)
        }

        /// One cursor per file before `file`, each over that file's own stretch.
        func fileCursors(before file: Int) -> [FileCursor] {
            (0..<min(file, fileEnds.count)).map {
                FileCursor(self, from: $0 == 0 ? 0 : fileEnds[$0 - 1], to: fileEnds[$0])
            }
        }

        /// Walks one earlier file's stretch of the table in step with queries that ascend,
        /// as the merge step of a sort-merge. Valid only while the queries ascend.
        struct FileCursor {
            private let table: NodeAreas
            private var at: Int
            private let end: Int

            init(_ table: NodeAreas, from: Int, to: Int) {
                self.table = table
                at = from
                end = to
            }

            mutating func contains(_ id: Int64) -> Bool {
                var position = at
                let found = table.keys.withUnsafeBufferPointer { k -> Bool in
                    while position < end, k[position] < id { position += 1 }
                    return position < end && k[position] == id
                }
                at = position
                return found
            }
        }

        /// Appends a whole block at once. The ids are checked for ascending order rather
        /// than assumed; out of order, they go in one at a time through `set`.
        func append(ids newIDs: [Int64], values newValues: [UInt16]) {
            guard let first = newIDs.first else { return }
            var ascending = first > lastKey
            if ascending {
                for i in 1..<newIDs.count where newIDs[i] <= newIDs[i - 1] {
                    ascending = false
                    break
                }
            }
            guard ascending else {
                for i in 0..<newIDs.count { set(newIDs[i], newValues[i]) }
                return
            }
            lastKey = newIDs[newIDs.count - 1]
            keys.append(contentsOf: newIDs)
            values.append(contentsOf: newValues)
        }

        /// A reader that walks the table in step with queries that ascend, falling back to
        /// a search whenever they do not, so an unsorted file is slower and not wrong.
        final class Cursor {
            private let table: NodeAreas
            /// 1 cursor per worker.
            @exclusivity(unchecked) private var at = 0

            init(_ table: NodeAreas) {
                self.table = table
            }

            func value(for id: Int64) -> UInt16? {
                let found: Int? = {
                    let keys = table.keys
                    guard at < keys.count else { return nil }
                    if keys[at] == id { return at }
                    guard keys[at] < id else { return nil }
                    // The usual step: forward a little, past nodes nothing asked about.
                    var next = at + 1
                    let limit = min(keys.count, at + Self.walk)
                    while next < limit, keys[next] < id { next += 1 }
                    if next < limit { return keys[next] == id ? next : nil }
                    return nil
                }()
                if let found {
                    at = found + 1
                    return table.values[found]
                }
                // Too far ahead to step to: search, and carry on walking from there.
                guard let index = table.find(id) else { return nil }
                at = index + 1
                return table.values[index]
            }

            /// How far to step before searching instead: sixty-four keys, one page of
            /// cache lines.
            private static let walk = 64
        }

        /// Names the set a node on a shared line belongs to, once it is in place.
        func setValue(at index: Int, to value: UInt16) {
            values[index] = value
        }

        func set(_ id: Int64, _ value: UInt16) {
            if id <= lastKey { runs.append(keys.count) }
            lastKey = id
            keys.append(id)
            values.append(value)
        }

        /// Every `fenceStride`-th key, so a lookup starts inside a small window instead of
        /// halving its way across the whole table.
        @exclusivity(unchecked) private var fences: [Int64] = []
        private static let fenceStride = 4096

        /// Builds the fences. Nothing may be added afterwards.
        func seal() {
            reconcileRuns()
            fences.removeAll(keepingCapacity: false)
            guard runs.count == 1, keys.count > Self.fenceStride else { return }
            fences.reserveCapacity(keys.count / Self.fenceStride + 1)
            var at = 0
            while at < keys.count {
                fences.append(keys[at])
                at += Self.fenceStride
            }
        }

        /// Gives every copy of an id that arrived in more than one run the latest run's
        /// value, so `find` and the walking cursor cannot disagree. One merge pass over
        /// each later run against each earlier one.
        private func reconcileRuns() {
            guard runs.count > 1 else { return }
            // An unsorted file has a run at every backward step, and merging each against
            // each is quadratic: the table is sorted instead. Nothing then depends on where
            // a file's stretch of it ends.
            if filesInterleave, runs.count > Self.mostRunsMerged {
                sortIntoOneRun()
                return
            }
            keys.withUnsafeBufferPointer { k in
                for later in 1..<runs.count {
                    let laterStart = runs[later]
                    let laterEnd = later + 1 < runs.count ? runs[later + 1] : k.count
                    for earlier in 0..<later {
                        var e = runs[earlier]
                        let earlierEnd = runs[earlier + 1]
                        var l = laterStart
                        while e < earlierEnd, l < laterEnd {
                            if k[e] < k[l] {
                                e += 1
                            } else if k[e] > k[l] {
                                l += 1
                            } else {
                                values[e] = values[l]
                                e += 1
                                l += 1
                            }
                        }
                    }
                }
            }
        }

        /// Past this many runs they are sorted into 1 run rather than merged pairwise.
        private static let mostRunsMerged = 64

        /// The whole table in id order, 1 entry an id, the latest value standing. Done
        /// in place: the only thing beside the table is 1 index an entry, 4 bytes wide
        /// while the table has fewer than 2^32 of them.
        private func sortIntoOneRun() {
            if keys.count <= Int(UInt32.max) {
                sortInPlace(indexedBy: UInt32.self)
            } else {
                sortInPlace(indexedBy: Int.self)
            }
            runs = [0]
            lastKey = keys.last ?? Int64.min
            fileEnds = fileEnds.map { _ in keys.count }
        }

        private func sortInPlace<Index: BinaryInteger>(indexedBy: Index.Type) {
            var order = sortedOrder(Index.self)
            permute(by: &order)
            closeUpRepeats()
        }

        /// Where each sorted entry comes from. By id, and for the same id by arrival, so
        /// the last of a repeat is the latest; each run is already in order, which the sort
        /// finds for itself.
        private func sortedOrder<Index: BinaryInteger>(_: Index.Type) -> [Index] {
            let count = keys.count
            var order = [Index](unsafeUninitializedCapacity: count) { buffer, filled in
                for i in 0..<count { buffer[i] = Index(i) }
                filled = count
            }
            keys.withUnsafeBufferPointer { k in
                order.sort { a, b in
                    let ka = k[Int(a)], kb = k[Int(b)]
                    return ka != kb ? ka < kb : a < b
                }
            }
            return order
        }

        /// Moves every entry to its place in `order`, cycle by cycle; a place already
        /// filled names itself.
        private func permute<Index: BinaryInteger>(by order: inout [Index]) {
            for first in 0..<order.count where Int(order[first]) != first {
                let key = keys[first], value = values[first]
                var at = first
                while true {
                    let from = Int(order[at])
                    order[at] = Index(at)
                    if from == first {
                        keys[at] = key
                        values[at] = value
                        break
                    }
                    keys[at] = keys[from]
                    values[at] = values[from]
                    at = from
                }
            }
        }

        /// Repeats are neighbours once sorted, the latest last: closed up towards the front.
        private func closeUpRepeats() {
            let count = keys.count
            var kept = 0
            for at in 0..<count {
                if kept > 0, keys[kept - 1] == keys[at] {
                    values[kept - 1] = values[at]
                } else {
                    keys[kept] = keys[at]
                    values[kept] = values[at]
                    kept += 1
                }
            }
            keys.removeLast(count - kept)
            values.removeLast(count - kept)
        }

        func get(_ id: Int64) -> UInt16? {
            guard let index = find(id) else { return nil }
            return values[index]
        }

        /// The value at an index `findAll(_:into:)` answered.
        func value(at index: Int) -> UInt16 { values[index] }

        /// Finds every id of `ids` at once, `out[i]` its index or -1, the searches run
        /// side by side so their waits on memory overlap. False, with nothing written,
        /// where the table has no fences and `find(_:)` has to walk its runs.
        func findAll(_ ids: UnsafeBufferPointer<Int64>, into out: UnsafeMutablePointer<Int64>) -> Bool {
            guard !fences.isEmpty, let first = ids.baseAddress else { return false }
            keys.withUnsafeBufferPointer { k in
                fences.withUnsafeBufferPointer { f in
                    kmap_find_fenced(
                        k.baseAddress,
                        k.count,
                        f.baseAddress,
                        f.count,
                        Self.fenceStride,
                        first,
                        ids.count,
                        out
                    )
                }
            }
            return true
        }

        /// Where an id sits in the table, or nil if it is not there.
        func find(_ id: Int64) -> Int? {
            // 1 run, fenced: the ordinary case, and the only one worth the extra table.
            fences.isEmpty ? findInRuns(id) : findFenced(id)
        }

        private func findFenced(_ id: Int64) -> Int? {
            keys.withUnsafeBufferPointer { k -> Int? in
                fences.withUnsafeBufferPointer { fence -> Int? in
                    // The last fence not past the id names the window it can be in.
                    var lo = 0, hi = fence.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if fence[mid] <= id { lo = mid + 1 } else { hi = mid }
                    }
                    guard lo > 0 else { return nil }
                    let start = (lo - 1) * Self.fenceStride
                    let end = min(start + Self.fenceStride, k.count)
                    var left = start, right = end
                    while left < right {
                        let mid = (left + right) / 2
                        if k[mid] < id { left = mid + 1 } else { right = mid }
                    }
                    return left < end && k[left] == id ? left : nil
                }
            }
        }

        /// Newest run first: an id can arrive twice, in the overlap 2 extracts share, and
        /// the later copy is the answer.
        private func findInRuns(_ id: Int64) -> Int? {
            keys.withUnsafeBufferPointer { k -> Int? in
                for index in stride(from: runs.count - 1, through: 0, by: -1) {
                    let start = runs[index]
                    let end = index + 1 < runs.count ? runs[index + 1] : k.count
                    var lo = start
                    var hi = end
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if k[mid] < id { lo = mid + 1 } else { hi = mid }
                    }
                    if lo < end && k[lo] == id { return lo }
                }
                return nil
            }
        }
    }
}
