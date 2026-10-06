import Foundation

/// Writes an OSM PBF. A blob handed over already compressed is copied through as it
/// stands; the rest are built and deflated on whichever cores are free and appended in
/// the order they were handed over. Output is streamed to the file rather than held whole.
final class PBFWriter {
    /// Upper bound on elements per block, keeping a blob inside the format's 32 MB
    /// uncompressed limit however large a batch the caller hands over.
    static let maxElementsPerBlock = 16_000

    /// Bytes reserved per element before a block is encoded. A deliberate underestimate:
    /// the buffers grow from here rather than from zero.
    static let idBytesPerNode = 2, coordinateBytesPerNode = 3, wayBodySlack = 32

    // Not private: the compression pipeline is a file of its own, and Swift's `private`
    // is one file.

    /// The writer's own serial queue: only the appending happens here, in ticket order.
    /// Building and compressing a block depends on no other block and runs elsewhere.
    let queue: DispatchQueue
    let handle: FileHandle
    let url: URL
    /// Where the file is written until `finish` puts it at `url`: a file stopped midway
    /// is never there to pass for whole, and a file at `url` being read is not cut short.
    let partial: URL
    /// Whether `finish` put it in place.
    var landed = false
    /// The next ticket to hand out; a batch's ticket is its place in the file.
    let tickets = Locked(0)
    /// Batches handed over and not yet appended, for `finish` to wait on.
    let inFlight = DispatchGroup()
    /// Batches compressed ahead of their turn, by ticket; and the ticket whose turn it is.
    /// Both belong to `queue`.
    var ready: [Int: Packed] = [:]
    var appended = 0
    var buffer: [UInt8] = []
    var finished = false
    /// The first write that failed, kept for `finish` to throw: a full disk is an
    /// ordinary event here, not a crash. Behind a lock so a caller can ask between batches.
    let failure = Locked<Error?>(nil)
    var writeFailure: Error? {
        get { failure.withLock { $0 } }
        set { failure.withLock { $0 = newValue } }
    }

    init(to url: URL) throws {
        self.url = url
        // A name of its own: a writer let go late takes only its own file with it.
        partial = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        handle = try FileTools.openForWriting(partial, appending: false)
        buffer.reserveCapacity(Self.flushThreshold)
        queue = DispatchQueue(label: "kmap.pbf.\(url.lastPathComponent)")
    }

    /// A writer let go without `finish` takes its partial file with it, once the batches
    /// still being compressed have let go of it too.
    deinit {
        try? handle.close()
        if !landed { FileTools.removeIfPresent(partial) }
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
        submit { [.toCompress(kind: PBFSchema.headerBlob, payload: payload)] }
    }

    private static func nanodegrees(_ degrees: Double) -> Int64 {
        Int64((degrees * PBFSchema.bboxScale).rounded())
    }

    /// Writes nodes dense: ids and coordinates delta-encoded, tags in one flat run.
    func nodes(_ batch: [Node]) {
        guard !batch.isEmpty else { return }
        submit { Self.nodePieces(batch) }
    }

    /// The blocks of a batch of nodes, in ascending ids, as the delta encoding and readers
    /// require.
    static func nodePieces(_ batch: [Node]) -> [Piece] {
        let ordered = ascending(batch) ? batch : batch.sorted { $0.id < $1.id }
        return stride(from: 0, to: ordered.count, by: Self.maxElementsPerBlock).map { start in
            .toCompress(
                kind: PBFSchema.dataBlob,
                payload: Self.nodeBlock(ordered[start..<min(start + Self.maxElementsPerBlock, ordered.count)])
            )
        }
    }

    private static func ascending(_ batch: [Node]) -> Bool {
        for i in batch.indices.dropFirst() where batch[i - 1].id > batch[i].id { return false }
        return true
    }

    private static func nodeBlock(_ batch: ArraySlice<Node>) -> [UInt8] {
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
            ids.zigzag(node.id &- lastID); lastID = node.id
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
        return block(strings: strings) { $0.bytesField(PBFSchema.groupDense, dense.bytes) }
    }

    func ways(_ batch: [Way]) {
        guard !batch.isEmpty else { return }
        submit { Self.wayPieces(batch) }
    }

    static func wayPieces(_ batch: [Way]) -> [Piece] {
        stride(from: 0, to: batch.count, by: Self.maxElementsPerBlock).map { start in
            .toCompress(
                kind: PBFSchema.dataBlob,
                payload: Self.wayBlock(batch[start..<min(start + Self.maxElementsPerBlock, batch.count)])
            )
        }
    }

    private static func wayBlock(_ batch: ArraySlice<Way>) -> [UInt8] {
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
                refs.zigzag(ref &- last)
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
        return block(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupWays, body) }
        }
    }

    /// Writes relations, one per group entry. Members are three parallel packed runs:
    /// roles as string-table indices, ids delta-encoded, kinds as the 0/1/2 enum.
    func relations(_ batch: [Relation]) {
        guard !batch.isEmpty else { return }
        submit {
            stride(from: 0, to: batch.count, by: Self.maxElementsPerBlock).map { start in
                .toCompress(
                    kind: PBFSchema.dataBlob,
                    payload: Self.relationBlock(batch[start..<min(start + Self.maxElementsPerBlock, batch.count)])
                )
            }
        }
    }

    private static func relationBlock(_ batch: ArraySlice<Relation>) -> [UInt8] {
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
                ids.zigzag(member.ref &- last)
                last = member.ref
                kinds.varint(UInt64(UInt32(bitPattern: member.kind)))
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
        return block(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupRelations, body) }
        }
    }

    /// A whole PrimitiveBlock: its string table, then the group `body` fills.
    static func block(strings: StringTable, _ body: (inout ProtoWriter) -> Void) -> [UInt8] {
        var group = ProtoWriter()
        body(&group)
        var block = ProtoWriter()
        block.message(PBFSchema.stringTable) { table in
            for word in strings.words { table.bytesField(PBFSchema.stringEntry, Array(word.utf8)) }
        }
        block.bytesField(PBFSchema.primitiveGroup, group.bytes)
        return block.bytes
    }
}
