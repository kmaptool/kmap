import Foundation

/// One block's nodes, gathered on whichever core decoded it.
struct BlockNodes: OSMSink {
    let wantedParts: OSMParts = .nodes

    var ids: [Int64] = []
    var lat: [Double] = []
    var lon: [Double] = []

    mutating func node(id: Int64, lat latitude: Double, lon longitude: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {
        ids.append(id)
        lat.append(latitude)
        lon.append(longitude)
    }

    mutating func clear() {
        ids.removeAll(keepingCapacity: true)
        lat.removeAll(keepingCapacity: true)
        lon.removeAll(keepingCapacity: true)
    }
}

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
            if id < lastID { at = 0 }        // a file whose ids do not ascend: start over
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

    /// Where a node is, or nil if the file does not carry it; an extract's own cut runs
    /// through ways.
    func place(of id: Int64) -> (lat: Double, lon: Double)? {
        guard let at = index(of: id), known[at] else { return nil }
        return (lat[at], lon[at])
    }
}
