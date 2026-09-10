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
    /// Ways that are an inner ring of some multipolygon: holes, not things.
    private var inner: Set<Int64> = []

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

    /// The relations whose outer ways are lifted, and the member roles that matter.
    static let multipolygonType = "multipolygon"
    static let boundaryType = "boundary"
    static let outerRole = "outer"
    static let innerRole = "inner"

    init(extract: URL, frame: BBox) throws {
        var sink = Builder(frame: frame)
        try PBFReader(url: extract).read(into: &sink)
        // The relation lift: a bare outer way is indexed under its relation's tags.
        // Shared by several relations, as a border between two districts or two
        // woods is, it is lifted only where they all mean one thing, with the tags of
        // the widest one. Walked in id order, so the slots are the same every run.
        for wayID in sink.bareOuterOf.keys.sorted() {
            guard let seen = sink.bareOuterOf[wayID],
                  let cells = sink.bareCells[wayID],
                  var tags = Self.lifted(from: seen, in: sink.relationTags) else { continue }
            tags[DefaultRuleBook.relationTypeKey] = nil
            sink.appendWay(id: wayID, cells: cells, tags: tags)
        }
        inner = sink.inner
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

    /// Tags of a way: its own, or the relation's where the lift gave it those.
    func tags(ofWay slot: Int32) -> [String: String] {
        ways[Int(slot)].tags
    }

    func isInner(_ slot: Int32) -> Bool { inner.contains(ways[Int(slot)].id) }

    /// The tags a bare outer way inherits from its relations, or nil where they
    /// disagree on what it means. The lowest admin level wins: mkgmap draws a border
    /// as the widest boundary it belongs to.
    static func lifted(from relations: Set<Int64>,
                       in tags: [Int64: [String: String]]) -> [String: String]? {
        let held = relations.sorted().compactMap { tags[$0] }
        guard !held.isEmpty,
              Set(held.map { DefaultRuleBook.meaning(of: $0) }).count == 1 else { return nil }
        let key = DefaultRuleBook.adminLevelKey
        return held.min { a, b in
            (Int(a[key] ?? "") ?? Int.max) < (Int(b[key] ?? "") ?? Int.max)
        }
    }

    fileprivate struct Builder: OSMSink {
        let frame: BBox
        var wantedParts: OSMParts { .all }

        // Node ids arrive ascending in a PBF, so parallel arrays + binary search
        // replace a five-million-entry dictionary. A file that breaks the order is
        // sorted once, before the first way asks.
        var coordIDs: [Int64] = []
        var coordCells: [UInt64] = []
        var ascending = true
        var nodes: [IndexedNode] = []
        var nodesByCell: [UInt64: [Int32]] = [:]
        var ways: [IndexedWay] = []
        var gramPairs: [(gram: UInt64, slot: Int32)] = []
        var relationTags: [Int64: [String: String]] = [:]
        /// The distinct multipolygons a bare way is an outer of.
        var bareOuterOf: [Int64: Set<Int64>] = [:]
        /// The cells of every bare way in frame, until the relations have been read.
        var bareCells: [Int64: [UInt64]] = [:]
        var inner: Set<Int64> = []

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
            if let last = coordIDs.last, id <= last { ascending = false }
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
            if !ascending { sortCoords() }
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
            let kind = tags[DefaultRuleBook.relationTypeKey]
            guard kind == GroundIndex.multipolygonType || kind == GroundIndex.boundaryType
            else { return }
            relationTags[id] = tags
            let kinds = Array(memberKinds), ids = Array(memberIDs), roles = Array(memberRoles)
            for i in 0..<kinds.count where kinds[i] == 1 {
                let role = block.text(Int(roles[i]))
                if role == GroundIndex.innerRole { inner.insert(ids[i]); continue }
                guard role.isEmpty || role == GroundIndex.outerRole else { continue }
                if bareCells[ids[i]] != nil {
                    bareOuterOf[ids[i], default: []].insert(id)
                }
            }
        }

        private mutating func sortCoords() {
            let order = coordIDs.indices.sorted { coordIDs[$0] < coordIDs[$1] }
            coordIDs = order.map { coordIDs[$0] }
            coordCells = order.map { coordCells[$0] }
            ascending = true
        }

        mutating func appendWay(id: Int64, cells: [UInt64], tags: [String: String]) {
            let slot = Int32(ways.count)
            ways.append(IndexedWay(id: id, cells: cells, tags: tags))
            for gram in GarminGrid.grams(of: cells) {
                gramPairs.append((gram, slot))
            }
            if cells.count == 2 { gramPairs.append((GarminGrid.edge(cells[0], cells[1]), slot)) }
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
