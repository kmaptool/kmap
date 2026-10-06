import Foundation

/// One decoded PrimitiveBlock, held long enough to decide whether it needs rewriting.
/// Tags are resolved to strings for every block, including those copied unchanged.
struct RewriteBlock: OSMSink {
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

    /// Read only where asked: their members, flat, relation `i` holding
    /// `memberStart[i]..<memberStart[i + 1]`.
    private var readsRelations = false
    private(set) var relationIDs: [Int64] = []
    private(set) var relationTags: [[(String, String)]] = []
    private var memberStart: [Int] = [0]
    private var memberKinds: [Int32] = []
    private var memberIDs: [Int64] = []
    private var memberRoles: [Int32] = []

    /// Decodes one block, its relations too where `relations`.
    ///
    /// - Parameter fields: decode buffers owned by the caller and reused between blocks.
    init(_ bytes: UnsafeRawBufferPointer, fields: inout PBFReader.Scratch, relations: Bool = false) throws {
        readsRelations = relations
        try PBFReader.decodeBlock(bytes, into: &self, fields: &fields)
    }

    /// Decodes one block, with decode buffers allocated for this call alone.
    init(_ bytes: UnsafeRawBufferPointer, relations: Bool = false) throws {
        var fields = PBFReader.Scratch()
        try self.init(bytes, fields: &fields, relations: relations)
    }

    var wantedParts: OSMParts { readsRelations ? [.nodes, .ways, .relations] : [.nodes, .ways] }

    /// The block's string table, decoded whole.
    private var strings: [String] = []

    /// Whether a string of the block holds characters no Garmin code page has: stress
    /// marks, zero-width joiners, emoji. Found on the table, once per block.
    private(set) var hasUnprintable = false

    mutating func begin(_ block: OSMBlock) {
        strings = block.strings.all()
        hasUnprintable = strings.contains { PBFRewriter.hasUnprintable($0) }
    }

    private func text(_ index: Int) -> String {
        index >= 0 && index < strings.count ? strings[index] : ""
    }

    mutating func sawGroup(_ part: OSMParts) {
        if part == .relations { hasRelations = true }
    }

    mutating func node(
        id: Int64,
        lat: Double,
        lon: Double,
        tags: ArraySlice<Int32>,
        block: OSMBlock
    ) {
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

    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        wayIDs.append(id)
        // `exactly`: `Array(refs)` would share the decoder's scratch buffer.
        wayRefs.append(refs.exactly)
        wayTags.append(zip(keys, values).map { (text(Int($0)), text(Int($1))) })
    }

    mutating func relation(
        id: Int64,
        memberKinds kinds: ArraySlice<Int32>,
        memberIDs ids: ArraySlice<Int64>,
        memberRoles roles: ArraySlice<Int32>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        relationIDs.append(id)
        relationTags.append(zip(keys, values).map { (text(Int($0)), text(Int($1))) })
        let count = min(kinds.count, ids.count)
        memberKinds += kinds.prefix(count)
        memberIDs += ids.prefix(count)
        // A member with no role in the table has the empty one, index 0.
        memberRoles += roles.prefix(count)
        if roles.count < count { memberRoles += repeatElement(0, count: count - roles.count) }
        memberStart.append(memberKinds.count)
    }

    /// Whether any element carries a description that only repeats its own name.
    var hasRedundantDescription: Bool {
        for tags in nodeTags where PBFRewriter.wouldTidy(tags) { return true }
        for (refs, tags) in zip(wayRefs, wayTags)
        where PBFRewriter.wouldTidy(tags, wordStays: PBFRewriter.wordStays(refs: refs, tags: tags)) {
            return true
        }
        // A block mixing relations with nodes or ways is copied whole, not refused, for its
        // relations alone.
        guard !hasNodes && !hasWays else { return false }
        for tags in relationTags where PBFRewriter.wouldTidy(tags) { return true }
        return false
    }

    /// Whether a node or a way, not only a relation, holds what `hasUnprintable` found:
    /// asked of a block mixing them, which is copied whole for its relations alone.
    var nodesOrWaysUnprintable: Bool {
        (nodeTags + wayTags).contains { $0.contains { PBFRewriter.hasUnprintable($0.1) } }
    }

    /// The relations as read, for writing again with their tags changed.
    func relations() -> [PBFWriter.Relation] {
        relationIDs.indices.map { i in
            let members = (memberStart[i]..<memberStart[i + 1]).map {
                PBFWriter.Relation.Member(kind: memberKinds[$0], ref: memberIDs[$0], role: text(Int(memberRoles[$0])))
            }
            return PBFWriter.Relation(id: relationIDs[i], members: members, tags: relationTags[i])
        }
    }

    /// Whether any way here runs through a node the repair merged away. Every node
    /// reference is tested, so the filter rejects most ids before the dictionary lookup.
    func usesAny(of merges: [Int64: Int64], filter: IDFilter) -> Bool {
        guard !filter.isEmpty else { return false }
        for refs in wayRefs
        where refs.contains(where: { filter.mayContain($0) && merges[$0] != nil }) { return true }
        return false
    }

    func nodes(
        movedBy moves: [Int64: (lat: Double, lon: Double)],
        filter: IDFilter
    ) -> [PBFWriter.Node] {
        (0..<nodeIDs.count).map { i in
            let place = filter.mayContain(nodeIDs[i]) ? moves[nodeIDs[i]] : nil
            return PBFWriter.Node(
                id: nodeIDs[i],
                lat: place?.lat ?? nodeLat[i],
                lon: place?.lon ?? nodeLon[i],
                tags: nodeTags[i]
            )
        }
    }

    /// Whether way `i` is one a route can run along, and so follows a merge: any highway,
    /// a ferry, a pier, a platform. A fence, a building or an area keeps its own node.
    /// Out of line: asked only where a merged node is met, and kept out of the loop every
    /// ref of every way runs through.
    @inline(never)
    private func isRoad(_ i: Int) -> Bool {
        wayTags[i].contains { key, value in
            key == "highway" || (key == "route" && value == "ferry")
                || (key == "man_made" && (value == "pier" || value == "jetty"))
                || (key == "railway" && value == "platform") || (key == "public_transport" && value == "platform")
        }
    }

    /// Returns the ways with repairs applied: references to merged nodes are replaced only in
    /// ways a route runs along; a fence, a gate drawn as a way or a landuse area keeps its node.
    /// Each inserted node goes after the node starting its segment, located by id, or before
    /// it for a way lengthened at its start. The filters of ways with inserts and of merged
    /// nodes reject nearly every id before its table is asked: every ref of every way passes
    /// here.
    func ways(
        inserting inserts: [Int64: [(after: Int64, segment: Int32, along: Double, node: Int64)]],
        merging merges: [Int64: Int64],
        wayFilter: IDFilter,
        mergeFilter: IDFilter
    ) -> [PBFWriter.Way] {
        // A filter says no for what it was not made from: one missing would drop repairs.
        assert(mergeFilter.isEmpty == merges.isEmpty, "the merge filter is made from the merges")
        assert(inserts.isEmpty || !wayFilter.isEmpty, "the way filter is made from the inserts")
        return (0..<wayIDs.count).map { i in
            var refs = wayRefs[i]
            if !mergeFilter.isEmpty {
                for at in refs.indices where mergeFilter.mayContain(refs[at]) {
                    if let stands = merges[refs[at]], isRoad(i) { refs[at] = stands }
                }
            }
            for insert in (wayFilter.mayContain(wayIDs[i]) ? inserts[wayIDs[i]] : nil) ?? [] {
                // The anchor node may itself have been merged away above.
                var anchor = insert.after
                while let stands = merges[anchor] { anchor = stands }
                // A closed way holds its first node twice; the planned position says
                // which of the 2 the segment started from.
                var at: Int?
                for (index, ref) in refs.enumerated() where ref == anchor {
                    if let held = at, abs(held - Int(insert.segment)) <= abs(index - Int(insert.segment)) {
                        continue
                    }
                    at = index
                }
                // So may the inserted node, if a later join gave it a partner.
                var node = insert.node
                while let stands = merges[node] { node = stands }
                if let at { refs.insert(node, at: insert.along < 0 ? at : at + 1) }
            }
            return PBFWriter.Way(id: wayIDs[i], refs: refs, tags: wayTags[i])
        }
    }
}
