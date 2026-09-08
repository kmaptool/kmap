import Foundation

/// One decoded PrimitiveBlock, held long enough to decide whether it needs rewriting.
/// Tags are resolved to strings for every block, including those copied unchanged.
struct Block: OSMSink {
    private(set) var nodeIDs: [Int64] = []
    private(set) var nodeLat: [Double] = []
    private(set) var nodeLon: [Double] = []
    private(set) var nodeTags: [[(String, String)]] = []

    private(set) var wayIDs: [Int64] = []
    private(set) var wayRefs: [[Int64]] = []
    private(set) var wayTags: [[(String, String)]] = []

    private(set) var hasRelations = false
    var hasNodes: Bool { !nodeIDs.isEmpty }
    var hasWays: Bool { !wayIDs.isEmpty }

    /// Decodes one block.
    ///
    /// - Parameter fields: decode buffers owned by the caller and reused between blocks.
    init(_ bytes: UnsafeRawBufferPointer, fields: inout PBFReader.Scratch) throws {
        try PBFReader.decodeBlock(bytes, into: &self, fields: &fields)
    }

    /// Decodes one block, with decode buffers allocated for this call alone.
    init(_ bytes: UnsafeRawBufferPointer) throws {
        var fields = PBFReader.Scratch()
        try self.init(bytes, fields: &fields)
    }

    var wantedParts: OSMParts { [.nodes, .ways] }

    /// The block's string table, decoded whole.
    private var strings: [String] = []

    mutating func begin(_ block: OSMBlock) {
        strings = block.strings.all()
    }

    private func text(_ index: Int) -> String {
        index >= 0 && index < strings.count ? strings[index] : ""
    }

    mutating func sawGroup(_ part: OSMParts) {
        if part == .relations { hasRelations = true }
    }

    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {
        var pairs: [(String, String)] = []
        pairs.reserveCapacity(tags.count / 2)
        var i = tags.startIndex
        while i + 1 < tags.endIndex {
            pairs.append((text(Int(tags[i])), text(Int(tags[i + 1]))))
            i += 2
        }
        nodeIDs.append(id)
        nodeLat.append(lat)
        nodeLon.append(lon)
        nodeTags.append(pairs)
    }

    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
        wayIDs.append(id)
        wayRefs.append(Array(refs))
        wayTags.append(zip(keys, values).map { (text(Int($0)), text(Int($1))) })
    }

    /// Whether any element carries a description that only repeats its own name.
    var hasRedundantDescription: Bool {
        for tags in nodeTags where PBFRewriter.wouldTidy(tags) { return true }
        for tags in wayTags where PBFRewriter.wouldTidy(tags) { return true }
        return false
    }

    /// Whether any way here runs through a node the repair merged away. Every node
    /// reference is tested, so the filter rejects most ids before the dictionary lookup.
    func usesAny(of merges: [Int64: Int64], filter: IDFilter) -> Bool {
        guard !filter.isEmpty else { return false }
        for refs in wayRefs
        where refs.contains(where: { filter.mayContain($0) && merges[$0] != nil }) { return true }
        return false
    }

    func nodes(movedBy moves: [Int64: (lat: Double, lon: Double)],
               filter: IDFilter) -> [PBFWriter.Node] {
        (0..<nodeIDs.count).map { i in
            let place = filter.mayContain(nodeIDs[i]) ? moves[nodeIDs[i]] : nil
            return PBFWriter.Node(id: nodeIDs[i], lat: place?.lat ?? nodeLat[i],
                                  lon: place?.lon ?? nodeLon[i], tags: nodeTags[i])
        }
    }

    /// Returns the ways with repairs applied: references to merged nodes are replaced, and
    /// each inserted node goes after the node starting its segment, located by id.
    func ways(inserting inserts: [Int64: [(after: Int64, segment: Int32, along: Double, node: Int64)]],
              merging merges: [Int64: Int64]) -> [PBFWriter.Way] {
        (0..<wayIDs.count).map { i in
            var refs = wayRefs[i]
            if !merges.isEmpty {
                for (at, ref) in refs.enumerated() {
                    if let stands = merges[ref] { refs[at] = stands }
                }
            }
            for insert in inserts[wayIDs[i]] ?? [] {
                // The anchor node may itself have been merged away above.
                var anchor = insert.after
                while let stands = merges[anchor] { anchor = stands }
                // A closed way holds its first node twice; the planned position says
                // which of the two the segment started from.
                var at: Int?
                for (index, ref) in refs.enumerated() where ref == anchor {
                    if let held = at, abs(held - Int(insert.segment)) <= abs(index - Int(insert.segment)) {
                        continue
                    }
                    at = index
                }
                if let at { refs.insert(insert.node, at: at + 1) }
            }
            return PBFWriter.Way(id: wayIDs[i], refs: refs, tags: wayTags[i])
        }
    }

}
