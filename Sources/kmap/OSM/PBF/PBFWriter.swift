import Foundation

/// Writes an OSM PBF. A blob handed over already compressed is copied through as it
/// stands; the rest are deflated a batch at a time across every core and appended in the
/// order they were handed over. Output is streamed to the file rather than held whole.
final class PBFWriter {
    /// One node. Version and timestamp are not carried; mkgmap reads neither.
    struct Node {
        var id: Int64
        var lat: Double
        var lon: Double
        var tags: [(String, String)]
    }

    struct Way {
        var id: Int64
        var refs: [Int64]
        var tags: [(String, String)]
    }

    struct Relation {
        /// Member kinds follow the PBF enum: 0 node, 1 way, 2 relation.
        struct Member {
            var kind: Int32
            var ref: Int64
            var role: String
        }
        var id: Int64
        var members: [Member]
        var tags: [(String, String)]
    }

    /// Upper bound on elements per block, keeping a blob inside the format's 32 MB
    /// uncompressed limit however large a batch the caller hands over.
    private static let maxElementsPerBlock = 16_000

    /// Bytes reserved per element before a block is encoded. A deliberate underestimate:
    /// the buffers grow from here rather than from zero.
    private static let idBytesPerNode = 2, coordinateBytesPerNode = 3, wayBodySlack = 32

    // Not private: the compression pipeline is a file of its own, and Swift's `private`
    // is one file.

    /// Serializing and compressing a block depends on no other block, so each writer works
    /// on a queue of its own.
    let queue: DispatchQueue
    let handle: FileHandle
    let url: URL
    /// Blocks awaiting compression, in the order handed over. Bounded by one batch, so the
    /// file streams rather than accumulates.
    var pending: [Piece] = []
    var buffer: [UInt8] = []
    var finished = false

    enum Piece {
        /// A blob already compressed by its original writer, passed through unchanged.
        case copied(header: [UInt8], blob: [UInt8])
        case toCompress(kind: String, payload: [UInt8])
    }

    init(to url: URL) throws {
        self.url = url
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.flushThreshold)
        queue = DispatchQueue(label: "kmap.pbf.\(url.lastPathComponent)")
        Self.live.enter()
    }

    deinit {
        if !finished { Self.live.leave() }
        try? handle.close()
    }

    /// Writes the header block. The bbox, when given, is read as the file's coverage;
    /// mkgmap sets a tile's TRE bounds from it.
    func header(
        bbox: (
            minLat: Double, minLon: Double,
            maxLat: Double, maxLon: Double
        )? = nil
    ) {
        var block = ProtoWriter()
        if let bbox {
            // The four corners are sint64: zigzag on the wire, unlike most of the format.
            block.message(PBFSchema.headerBBox) { box in
                box.zigzagField(PBFSchema.bboxLeft, Self.nanodegrees(bbox.minLon))
                box.zigzagField(PBFSchema.bboxRight, Self.nanodegrees(bbox.maxLon))
                box.zigzagField(PBFSchema.bboxTop, Self.nanodegrees(bbox.maxLat))
                box.zigzagField(PBFSchema.bboxBottom, Self.nanodegrees(bbox.minLat))
            }
        }
        for feature in PBFSchema.requiredFeatures {
            block.stringField(PBFSchema.headerRequiredFeature, feature)
        }
        block.stringField(PBFSchema.headerWritingProgram, PBFSchema.writingProgram)
        let payload = block.bytes
        submit { [self] in emit(kind: PBFSchema.headerBlob, payload: payload) }
    }

    private static func nanodegrees(_ degrees: Double) -> Int64 {
        Int64((degrees * PBFSchema.bboxScale).rounded())
    }

    /// Writes nodes dense: ids and coordinates delta-encoded, tags in one flat run.
    func nodes(_ batch: [Node]) {
        guard !batch.isEmpty else { return }
        submit { [self] in
            // Ascending ids, as the delta encoding and readers require.
            let ordered = batch.sorted { $0.id < $1.id }
            for start in stride(from: 0, to: ordered.count, by: Self.maxElementsPerBlock) {
                writeNodeBlock(
                    ordered[start..<min(start + Self.maxElementsPerBlock, ordered.count)]
                )
            }
        }
    }

    private func writeNodeBlock(_ batch: ArraySlice<Node>) {
        var strings = StringTable()
        var ids = ProtoWriter(), lats = ProtoWriter(), lons = ProtoWriter()
        var tags = ProtoWriter()
        ids.reserve(batch.count * Self.idBytesPerNode)
        lats.reserve(batch.count * Self.coordinateBytesPerNode)
        lons.reserve(batch.count * Self.coordinateBytesPerNode)
        tags.reserve(batch.count)
        var lastID: Int64 = 0, lastLat: Int64 = 0, lastLon: Int64 = 0
        for node in batch {
            let lat = Int64((node.lat * PBFSchema.coordinateScale).rounded())
            let lon = Int64((node.lon * PBFSchema.coordinateScale).rounded())
            ids.zigzag(node.id - lastID); lastID = node.id
            lats.zigzag(lat - lastLat); lastLat = lat
            lons.zigzag(lon - lastLon); lastLon = lon
            for (key, value) in node.tags {
                tags.varint(UInt64(strings.index(key)))
                tags.varint(UInt64(strings.index(value)))
            }
            tags.varint(0)
        }

        var dense = ProtoWriter()
        dense.bytesField(PBFSchema.denseID, ids.bytes)
        dense.bytesField(PBFSchema.denseLat, lats.bytes)
        dense.bytesField(PBFSchema.denseLon, lons.bytes)
        dense.bytesField(PBFSchema.denseKeysVals, tags.bytes)
        emitBlock(strings: strings) { $0.bytesField(PBFSchema.groupDense, dense.bytes) }
    }

    func ways(_ batch: [Way]) {
        guard !batch.isEmpty else { return }
        submit { [self] in
            for start in stride(from: 0, to: batch.count, by: Self.maxElementsPerBlock) {
                writeWayBlock(batch[start..<min(start + Self.maxElementsPerBlock, batch.count)])
            }
        }
    }

    private func writeWayBlock(_ batch: ArraySlice<Way>) {
        var strings = StringTable()
        var bodies: [[UInt8]] = []
        bodies.reserveCapacity(batch.count)
        // Scratch writers, reset between ways with their buffers kept. Their bytes are copied
        // into `body`, so none escape.
        var keys = ProtoWriter(), values = ProtoWriter(), refs = ProtoWriter()
        for way in batch {
            keys.reset(); values.reset(); refs.reset()
            for (key, value) in way.tags {
                keys.varint(UInt64(strings.index(key)))
                values.varint(UInt64(strings.index(value)))
            }
            var last: Int64 = 0
            for ref in way.refs {
                refs.zigzag(ref - last)
                last = ref
            }
            // A fresh writer, since it escapes into `bodies`; sized to allocate once.
            var body = ProtoWriter()
            body.reserve(
                keys.bytes.count + values.bytes.count + refs.bytes.count
                    + Self.wayBodySlack
            )
            body.varintField(PBFSchema.elementID, way.id)
            if !keys.bytes.isEmpty {
                body.bytesField(PBFSchema.elementKeys, keys.bytes)
                body.bytesField(PBFSchema.elementVals, values.bytes)
            }
            body.bytesField(PBFSchema.wayRefs, refs.bytes)
            bodies.append(body.bytes)
        }
        emitBlock(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupWays, body) }
        }
    }

    /// Writes relations, one per group entry. Members are three parallel packed runs:
    /// roles as string-table indices, ids delta-encoded, kinds as the 0/1/2 enum.
    func relations(_ batch: [Relation]) {
        guard !batch.isEmpty else { return }
        submit { [self] in
            for start in stride(from: 0, to: batch.count, by: Self.maxElementsPerBlock) {
                writeRelationBlock(
                    batch[start..<min(start + Self.maxElementsPerBlock, batch.count)]
                )
            }
        }
    }

    private func writeRelationBlock(_ batch: ArraySlice<Relation>) {
        var strings = StringTable()
        var bodies: [[UInt8]] = []
        bodies.reserveCapacity(batch.count)
        for relation in batch {
            var keys = ProtoWriter(), values = ProtoWriter()
            for (key, value) in relation.tags {
                keys.varint(UInt64(strings.index(key)))
                values.varint(UInt64(strings.index(value)))
            }
            var roles = ProtoWriter(), ids = ProtoWriter(), kinds = ProtoWriter()
            var last: Int64 = 0
            for member in relation.members {
                roles.varint(UInt64(strings.index(member.role)))
                ids.zigzag(member.ref - last)
                last = member.ref
                kinds.varint(UInt64(member.kind))
            }
            var body = ProtoWriter()
            body.varintField(PBFSchema.elementID, relation.id)
            if !keys.bytes.isEmpty {
                body.bytesField(PBFSchema.elementKeys, keys.bytes)
                body.bytesField(PBFSchema.elementVals, values.bytes)
            }
            if !relation.members.isEmpty {
                body.bytesField(PBFSchema.memberRoles, roles.bytes)
                body.bytesField(PBFSchema.memberIDs, ids.bytes)
                body.bytesField(PBFSchema.memberKinds, kinds.bytes)
            }
            bodies.append(body.bytes)
        }
        emitBlock(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupRelations, body) }
        }
    }

    private func emitBlock(strings: StringTable, _ body: (inout ProtoWriter) -> Void) {
        var group = ProtoWriter()
        body(&group)
        var block = ProtoWriter()
        block.message(PBFSchema.stringTable) { table in
            for word in strings.words { table.bytesField(PBFSchema.stringEntry, Array(word.utf8)) }
        }
        block.bytesField(PBFSchema.primitiveGroup, group.bytes)
        emit(kind: PBFSchema.dataBlob, payload: block.bytes)
    }

    private func emit(kind: String, payload: [UInt8]) {
        enqueue(.toCompress(kind: kind, payload: payload))
    }
}

/// A block's strings, interned as it is built. Index 0 is reserved and always empty.
struct StringTable {
    private(set) var words: [String] = [""]
    private var seen: [String: Int32] = [:]

    mutating func index(_ word: String) -> Int32 {
        if let known = seen[word] { return known }
        words.append(word)
        let made = Int32(words.count - 1)
        seen[word] = made
        return made
    }
}
