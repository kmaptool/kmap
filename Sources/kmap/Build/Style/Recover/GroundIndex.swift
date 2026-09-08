import Foundation

/// The OSM extract, indexed so that a map element can name the way it was compiled from.
///
/// Two passes: nodes first, for coordinates and for point matching, then ways, each
/// becoming a chain of grid cells and a set of k-grams pointing back at it. Only tagged
/// ways are indexed, and only what falls inside the map's own frame.
struct GroundIndex {
    /// (gram, way slot) pairs sorted by gram, built in one sort and answered by binary
    /// search. A gram shared by more than `tooCommonGram` ways is a grid artefact rather
    /// than a fingerprint, and is skipped at query time.
    private(set) var gramPairs: [(gram: UInt64, slot: Int32)] = []
    /// Way slot -> its tags and cells, for verification and for the evidence table.
    private(set) var ways: [IndexedWay] = []
    /// Tagged nodes by grid cell, for point elements.
    private(set) var nodesByCell: [UInt64: [Int32]] = [:]
    private(set) var nodes: [IndexedNode] = []

    struct IndexedWay {
        let id: Int64
        let cells: [UInt64]
        let tags: [String: String]
    }

    struct IndexedNode {
        let id: Int64
        let cell: UInt64
        let tags: [String: String]
    }

    static let tooCommonGram = 16

    init(extract: URL, frame: BBox) throws {
        var sink = Builder(frame: frame)
        try PBFReader(url: extract).read(into: &sink)
        // The relation lift: a bare outer way in exactly one multipolygon is indexed under
        // that relation's tags. Walked in id order, so the slots are the same every run.
        for wayID in sink.bareOuterOf.keys.sorted() {
            guard let seen = sink.bareOuterOf[wayID], seen.count == 1,
                  let only = seen.first, var tags = sink.relationTags[only],
                  let cells = sink.bareCells[wayID] else { continue }
            // The relation's kind is how it was assembled, not what it means.
            tags["type"] = nil
            sink.appendWay(id: wayID, cells: cells, tags: tags)
        }
        ways = sink.ways
        nodes = sink.nodes
        nodesByCell = sink.nodesByCell
        var pairs = sink.gramPairs
        pairs.sort { $0.gram < $1.gram }
        gramPairs = pairs
    }

    /// The way slots holding this gram, or nothing for a degenerate one.
    func slots(of gram: UInt64) -> ArraySlice<(gram: UInt64, slot: Int32)> {
        var low = 0, high = gramPairs.count
        while low < high {
            let mid = (low + high) / 2
            if gramPairs[mid].gram < gram { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < gramPairs.count, gramPairs[end].gram == gram { end += 1 }
        guard end - low <= Self.tooCommonGram else { return gramPairs[low..<low] }
        return gramPairs[low..<end]
    }

    /// Tags of a way — its own, or the relation's where the lift gave it those.
    func tags(ofWay slot: Int32) -> [String: String] {
        ways[Int(slot)].tags
    }

    fileprivate struct Builder: OSMSink {
        let frame: BBox
        var wantedParts: OSMParts { .all }

        // Node ids arrive ascending in a PBF, so parallel arrays + binary search
        // replace a five-million-entry dictionary.
        var coordIDs: [Int64] = []
        var coordCells: [UInt64] = []
        var nodes: [IndexedNode] = []
        var nodesByCell: [UInt64: [Int32]] = [:]
        var ways: [IndexedWay] = []
        var gramPairs: [(gram: UInt64, slot: Int32)] = []
        var relationTags: [Int64: [String: String]] = [:]
        /// The distinct multipolygons a bare way is an outer of.
        var bareOuterOf: [Int64: Set<Int64>] = [:]
        /// The cells of every bare way in frame, until the relations have been read.
        var bareCells: [Int64: [UInt64]] = [:]

        init(frame: BBox) { self.frame = frame }

        private func cell(of ref: Int64) -> UInt64? {
            var low = 0, high = coordIDs.count
            while low < high {
                let mid = (low + high) / 2
                if coordIDs[mid] < ref { low = mid + 1 } else { high = mid }
            }
            guard low < coordIDs.count, coordIDs[low] == ref else { return nil }
            return coordCells[low]
        }

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            guard frame.contains(lat: lat, lon: lon) else { return }
            let cell = GarminGrid.cell(lat: lat, lon: lon)
            coordIDs.append(id)
            coordCells.append(cell)
            guard !tags.isEmpty else { return }
            let slot = Int32(nodes.count)
            nodes.append(IndexedNode(id: id, cell: cell, tags: decode(pairs: tags, block)))
            nodesByCell[cell, default: []].append(slot)
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                          block: OSMBlock) {
            var cells: [UInt64] = []
            cells.reserveCapacity(refs.count)
            for ref in refs {
                guard let cell = cell(of: ref) else { continue }
                cells.append(cell)
            }
            guard cells.count >= 2 else { return }
            let tags = decode(keys: keys, values: values, block)
            if tags.isEmpty {
                // Not indexed yet, but kept: a multipolygon may give it meaning.
                bareCells[id] = cells
                return
            }
            appendWay(id: id, cells: cells, tags: tags)
        }

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
            let tags = decode(keys: keys, values: values, block)
            guard tags["type"] == "multipolygon" || tags["type"] == "boundary" else { return }
            relationTags[id] = tags
            let kinds = Array(memberKinds), ids = Array(memberIDs), roles = Array(memberRoles)
            for i in 0..<kinds.count where kinds[i] == 1 {
                let role = block.text(Int(roles[i]))
                guard role.isEmpty || role == "outer" else { continue }
                if bareCells[ids[i]] != nil {
                    bareOuterOf[ids[i], default: []].insert(id)
                }
            }
        }

        mutating func appendWay(id: Int64, cells: [UInt64], tags: [String: String]) {
            let slot = Int32(ways.count)
            ways.append(IndexedWay(id: id, cells: cells, tags: tags))
            for gram in GarminGrid.grams(of: cells) {
                gramPairs.append((gram, slot))
            }
        }

        private func decode(pairs: ArraySlice<Int32>, _ block: OSMBlock) -> [String: String] {
            var out: [String: String] = [:]
            var i = pairs.startIndex
            while i + 1 < pairs.endIndex {
                out[block.text(Int(pairs[i]))] = block.text(Int(pairs[i + 1]))
                i += 2
            }
            return out
        }

        private func decode(keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                            _ block: OSMBlock) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in zip(keys, values) {
                out[block.text(Int(k))] = block.text(Int(v))
            }
            return out
        }
    }
}
