import Foundation

/// Elements handed over in runs, their tags already numbered among themselves.
///
/// An element with tags of its own is an array for the tags, 2 strings retained a tag,
/// and every one of those strings hashed again when its block is written. A run keeps
/// its elements as columns and its strings once; the block then looks a string up once
/// a run rather than once a tag. What is written is the same, byte for byte.
extension PBFWriter {
    struct NodeChunk: Sendable {
        var ids: [Int64] = []
        var lats: [Double] = []
        var lons: [Double] = []
        /// Where each node's tags end in `tags`.
        var tagEnds: [Int32] = []
        /// Key and value in turn, as places in `strings`.
        var tags: [Int32] = []
        var strings: [String] = []

        var count: Int { ids.count }

        /// The nodes of `range` as the writer's ordinary nodes.
        func nodes(_ range: Range<Int>) -> [Node] {
            range.map { at in
                let start = at == 0 ? 0 : Int(tagEnds[at - 1])
                let pairs = stride(from: start, to: Int(tagEnds[at]), by: 2).map {
                    (strings[Int(tags[$0])], strings[Int(tags[$0 + 1])])
                }
                return Node(id: ids[at], lat: lats[at], lon: lons[at], tags: pairs)
            }
        }
    }

    struct WayChunk: Sendable {
        var ids: [Int64] = []
        /// Where each way's nodes end in `refs`.
        var refEnds: [Int32] = []
        var refs: [Int64] = []
        var tagEnds: [Int32] = []
        var tags: [Int32] = []
        var strings: [String] = []

        var count: Int { ids.count }

        func ways(_ range: Range<Int>) -> [Way] {
            range.map { at in
                let start = at == 0 ? 0 : Int(tagEnds[at - 1])
                let pairs = stride(from: start, to: Int(tagEnds[at]), by: 2).map {
                    (strings[Int(tags[$0])], strings[Int(tags[$0 + 1])])
                }
                let first = at == 0 ? 0 : Int(refEnds[at - 1])
                return Way(id: ids[at], refs: Array(refs[first..<Int(refEnds[at])]), tags: pairs)
            }
        }
    }

    /// Writes a batch of node runs as `nodes(_:)` writes the same nodes one by one.
    func nodes(runs: [(chunk: NodeChunk, range: Range<Int>)]) {
        let total = runs.reduce(0) { $0 + $1.range.count }
        guard total > 0 else { return }
        submit {
            // 1 block of ids already ascending is the case the runs are made for; anything
            // else goes the ordinary way, which sorts and cuts.
            guard total <= Self.maxElementsPerBlock, Self.ascends(runs) else {
                return Self.nodePieces(runs.flatMap { $0.chunk.nodes($0.range) })
            }
            return [.toCompress(kind: PBFSchema.dataBlob, payload: Self.nodeBlock(runs, count: total))]
        }
    }

    /// Writes a batch of way runs as `ways(_:)` writes the same ways one by one.
    func ways(runs: [(chunk: WayChunk, range: Range<Int>)]) {
        let total = runs.reduce(0) { $0 + $1.range.count }
        guard total > 0 else { return }
        submit {
            guard total <= Self.maxElementsPerBlock else {
                return Self.wayPieces(runs.flatMap { $0.chunk.ways($0.range) })
            }
            return [.toCompress(kind: PBFSchema.dataBlob, payload: Self.wayBlock(runs, count: total))]
        }
    }

    private static func ascends(_ runs: [(chunk: NodeChunk, range: Range<Int>)]) -> Bool {
        var last = Int64.min
        for (chunk, range) in runs {
            for at in range {
                if chunk.ids[at] <= last { return false }
                last = chunk.ids[at]
            }
        }
        return true
    }

    private static func nodeBlock(_ runs: [(chunk: NodeChunk, range: Range<Int>)], count: Int) -> [UInt8] {
        var strings = StringTable()
        var ids = ProtoWriter(), lats = ProtoWriter(), lons = ProtoWriter()
        var tags = ProtoWriter()
        ids.reserve(count * Self.idBytesPerNode)
        lats.reserve(count * Self.coordinateBytesPerNode)
        lons.reserve(count * Self.coordinateBytesPerNode)
        tags.reserve(count)
        var lastID: Int64 = 0, lastLat: Int64 = 0, lastLon: Int64 = 0
        // A run's place in the block's table, found on first meeting and kept.
        var known: [Int32] = []
        for (chunk, range) in runs {
            known.removeAll(keepingCapacity: true)
            known.append(contentsOf: repeatElement(-1, count: chunk.strings.count))
            for at in range {
                let lat = Int64((chunk.lats[at] * PBFSchema.coordinateScale).rounded())
                let lon = Int64((chunk.lons[at] * PBFSchema.coordinateScale).rounded())
                ids.zigzag(chunk.ids[at] &- lastID); lastID = chunk.ids[at]
                lats.zigzag(lat - lastLat); lastLat = lat
                lons.zigzag(lon - lastLon); lastLon = lon
                for tag in (at == 0 ? 0 : Int(chunk.tagEnds[at - 1]))..<Int(chunk.tagEnds[at]) {
                    let local = Int(chunk.tags[tag])
                    if known[local] < 0 { known[local] = strings.index(chunk.strings[local]) }
                    tags.varint(UInt64(known[local]))
                }
                tags.varint(0)
            }
        }

        var dense = ProtoWriter()
        dense.bytesField(PBFSchema.denseID, ids.bytes)
        dense.bytesField(PBFSchema.denseLat, lats.bytes)
        dense.bytesField(PBFSchema.denseLon, lons.bytes)
        dense.bytesField(PBFSchema.denseKeysVals, tags.bytes)
        return block(strings: strings) { $0.bytesField(PBFSchema.groupDense, dense.bytes) }
    }

    private static func wayBlock(_ runs: [(chunk: WayChunk, range: Range<Int>)], count: Int) -> [UInt8] {
        var strings = StringTable()
        var bodies: [[UInt8]] = []
        bodies.reserveCapacity(count)
        var keys = ProtoWriter(), values = ProtoWriter(), refs = ProtoWriter()
        var known: [Int32] = []
        for (chunk, range) in runs {
            known.removeAll(keepingCapacity: true)
            known.append(contentsOf: repeatElement(-1, count: chunk.strings.count))
            for at in range {
                keys.reset(); values.reset(); refs.reset()
                var tag = at == 0 ? 0 : Int(chunk.tagEnds[at - 1])
                let tagEnd = Int(chunk.tagEnds[at])
                while tag < tagEnd {
                    let key = Int(chunk.tags[tag]), value = Int(chunk.tags[tag + 1])
                    if known[key] < 0 { known[key] = strings.index(chunk.strings[key]) }
                    keys.varint(UInt64(known[key]))
                    if known[value] < 0 { known[value] = strings.index(chunk.strings[value]) }
                    values.varint(UInt64(known[value]))
                    tag += 2
                }
                var last: Int64 = 0
                for ref in (at == 0 ? 0 : Int(chunk.refEnds[at - 1]))..<Int(chunk.refEnds[at]) {
                    refs.zigzag(chunk.refs[ref] &- last)
                    last = chunk.refs[ref]
                }
                var body = ProtoWriter()
                body.reserve(keys.bytes.count + values.bytes.count + refs.bytes.count + Self.wayBodySlack)
                body.varintField(PBFSchema.elementID, chunk.ids[at])
                if !keys.bytes.isEmpty {
                    body.bytesField(PBFSchema.elementKeys, keys.bytes)
                    body.bytesField(PBFSchema.elementVals, values.bytes)
                }
                body.bytesField(PBFSchema.wayRefs, refs.bytes)
                bodies.append(body.bytes)
            }
        }
        return block(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupWays, body) }
        }
    }
}
