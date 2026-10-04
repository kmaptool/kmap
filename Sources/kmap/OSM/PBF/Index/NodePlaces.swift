import CVector
import Foundation

/// Where a wanted set of nodes are. A PBF stores nodes before the ways that name them, so
/// way geometry needs a second pass. The file's nodes and the wanted ids both ascend, so
/// collecting them is a merge; lookup by id goes through a fence table of every 4096th id.
struct NodePlaces {
    private let wanted: [Int64]
    private let fences: [Int64]
    private(set) var lat: [Double]
    private(set) var lon: [Double]
    private(set) var known: [Bool]
    private var at = 0
    private var lastID = Int64.min

    /// A fence is taken every 4096th id, which keeps the fences in cache for any file.
    private static let fenceStride = 4096

    /// `wanted` must be sorted and hold each id once -- `wantedIDs(from:)` does that.
    init(wanted: [Int64]) {
        // The search counts on it: an id 1 above another is looked for right after it.
        precondition(zip(wanted, wanted.dropFirst()).allSatisfy { $0 < $1 }, "wanted ids must ascend, each once")
        self.wanted = wanted
        lat = [Double](repeating: 0, count: wanted.count)
        lon = [Double](repeating: 0, count: wanted.count)
        known = [Bool](repeating: false, count: wanted.count)

        guard wanted.count > Self.fenceStride else {
            fences = []
            return
        }
        var marks: [Int64] = []
        marks.reserveCapacity(wanted.count / Self.fenceStride + 1)
        var index = 0
        while index < wanted.count {
            marks.append(wanted[index])
            index += Self.fenceStride
        }
        fences = marks
    }

    /// Returns the ids a set of way references asks about: sorted, each once.
    static func wantedIDs(from refs: [Int64]) -> [Int64] { IDSort.unique(of: [refs]) }

    /// The same, from several runs at once, without joining them first.
    static func wantedIDs(from runs: [[Int64]]) -> [Int64] { IDSort.unique(of: runs) }

    /// Takes one block's nodes, in file order.
    mutating func take(_ block: BlockNodes) {
        for i in 0..<block.ids.count {
            let id = block.ids[i]
            if id < lastID { at = 0 }  // a file whose ids do not ascend: start over
            lastID = id
            while at < wanted.count, wanted[at] < id { at += 1 }
            guard at < wanted.count, wanted[at] == id else { continue }
            lat[at] = block.lat[i]
            lon[at] = block.lon[i]
            known[at] = true
            at += 1
        }
    }

    /// Reads a file and returns where every wanted node is.
    static func gather(_ wanted: [Int64], from url: URL) throws -> NodePlaces {
        var places = NodePlaces(wanted: wanted)
        try PBFReader(url: url).readInOrder(make: { BlockNodes() }) { block in
            places.take(block)
            block.clear()
        }
        return places
    }

    /// Where the id sits in the wanted list, or nil if it was not asked for.
    func index(of id: Int64) -> Int? {
        var low = 0
        var high = wanted.count - 1
        if !fences.isEmpty {
            var lo = 0, hi = fences.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if fences[mid] <= id { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return nil }
            low = (lo - 1) * Self.fenceStride
            high = min(low + Self.fenceStride, wanted.count) - 1
        }
        while low <= high {
            let mid = (low + high) / 2
            if wanted[mid] == id { return mid }
            if wanted[mid] < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// Ids searched per task when many are looked up at once.
    private static let idsPerLane = 1 << 14

    /// For each of `ids`, its slot in `lat` and `lon`, or -1 where it was not asked for or
    /// the file does not carry it. The searches run side by side in C, so their waits on
    /// memory overlap, and a stretch of ids goes to each core.
    func slots(of ids: UnsafeBufferPointer<Int64>, into out: UnsafeMutablePointer<Int64>) {
        let count = ids.count
        guard count > 0, let first = ids.baseAddress else { return }
        guard !fences.isEmpty else {
            for i in 0..<count {
                if let at = index(of: first[i]), known[at] { out[i] = Int64(at) } else { out[i] = -1 }
            }
            return
        }
        wanted.withUnsafeBufferPointer { keys in
            fences.withUnsafeBufferPointer { fences in
                known.withUnsafeBufferPointer { known in
                    // Each lane writes its own stretch of `out`; the tables are only read.
                    nonisolated(unsafe) let keys = keys, fences = fences, known = known
                    nonisolated(unsafe) let first = first, out = out
                    let perLane = Self.idsPerLane
                    DispatchQueue.concurrentPerform(iterations: (count + perLane - 1) / perLane) { lane in
                        let low = lane * perLane, high = min(count, low + perLane)
                        kmap_find_fenced(
                            keys.baseAddress,
                            keys.count,
                            fences.baseAddress,
                            fences.count,
                            Self.fenceStride,
                            first + low,
                            high - low,
                            out + low
                        )
                        for i in low..<high where out[i] >= 0 && !known[Int(out[i])] { out[i] = -1 }
                    }
                }
            }
        }
    }

    /// Where a node is, or nil if the file does not carry it; an extract's own cut runs
    /// through ways.
    func place(of id: Int64) -> (lat: Double, lon: Double)? {
        guard let at = index(of: id), known[at] else { return nil }
        return (lat[at], lon[at])
    }
}
