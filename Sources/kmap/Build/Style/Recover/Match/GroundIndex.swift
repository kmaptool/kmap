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
                var tags = Self.lifted(from: seen, in: sink.relationTags)
            else { continue }
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
    static func lifted(
        from relations: Set<Int64>,
        in tags: [Int64: [String: String]]
    ) -> [String: String]? {
        let held = relations.sorted().compactMap { tags[$0] }
        guard !held.isEmpty,
            Set(held.map { DefaultRuleBook.meaning(of: $0) }).count == 1
        else { return nil }
        let key = DefaultRuleBook.adminLevelKey
        return held.min { a, b in
            (Int(a[key] ?? "") ?? Int.max) < (Int(b[key] ?? "") ?? Int.max)
        }
    }
}
