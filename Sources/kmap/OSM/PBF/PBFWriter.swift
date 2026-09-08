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

    /// Field numbers from the OSM PBF schema.
    private enum Field {
        static let blobHeaderKind = 1, blobHeaderSize = 3
        static let blobRaw = 1, blobRawSize = 2, blobZlib = 3
        static let stringTable = 1, primitiveGroup = 2
        static let headerBBox = 1, headerRequiredFeature = 4, headerWritingProgram = 16
        static let bboxLeft = 1, bboxRight = 2, bboxTop = 3, bboxBottom = 4
        static let groupDense = 2, groupWays = 3, groupRelations = 4
        static let denseID = 1, denseLat = 8, denseLon = 9, denseKeysVals = 10
        static let elementID = 1, elementKeys = 2, elementVals = 3
        static let wayRefs = 8
        static let memberRoles = 8, memberIDs = 9, memberKinds = 10
        static let stringEntry = 1
    }

    /// Upper bound on elements per block, keeping a blob inside the format's 32 MB
    /// uncompressed limit however large a batch the caller hands over.
    private static let maxElementsPerBlock = 16_000

    /// Coordinates are stored at the format's default granularity: one stored unit is a
    /// hundred nanodegrees, that is 1e-7 of a degree.
    private static let coordinateScale = 1e7

    /// Nanodegrees, which is what a header bounding box is written in.
    private static let bboxScale = 1e9

    /// Serializing and compressing a block depends on no other block, so each writer works
    /// on a queue of its own.
    private let queue: DispatchQueue
    /// How many batches may await writing across every writer at once. Shared, so the memory
    /// held is bounded by the machine rather than by the number of writers open.
    private static let room = DispatchSemaphore(
        value: 8)

    /// Writers currently open. A lone writer compresses its batch across every core; with
    /// several open, each keeps to its own queue.
    private static let live = LiveCount()

    final class LiveCount {
        private let lock = NSLock()
        private var value = 0
        func enter() { lock.lock(); value += 1; lock.unlock() }
        func leave() { lock.lock(); value -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let handle: FileHandle
    private let url: URL
    /// Blocks awaiting compression, in the order handed over. Bounded by one batch, so the
    /// file streams rather than accumulates.
    private var pending: [Piece] = []
    private var buffer: [UInt8] = []
    private var finished = false

    private enum Piece {
        /// A blob already compressed by its original writer, passed through unchanged.
        case copied(header: [UInt8], blob: [UInt8])
        case toCompress(kind: String, payload: [UInt8])
    }

    /// How many blocks are compressed in one go: one per core.
    private static let compressionBatch =
        max(2, Machine.cores)

    /// Bytes gathered before writing to disk. Small, since a split keeps one writer open per
    /// tile and each holds this much.
    private static let flushThreshold = 1 << 20

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

    /// Hands a batch to this writer's own queue, waiting if one is already there.
    private func submit(_ work: @escaping () -> Void) {
        Self.room.wait()
        queue.async {
            work()
            Self.room.signal()
        }
    }

    /// Copies a blob through untouched, header and all.
    func copy(header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer) {
        // Copied here rather than on the queue: these point into a mapped file the caller is
        // still walking.
        let headerBytes = Array(header)
        let blobBytes = Array(blob)
        submit { [self] in enqueue(.copied(header: headerBytes, blob: blobBytes)) }
    }

    /// Writes the header block. The bbox, when given, is read as the file's coverage;
    /// mkgmap sets a tile's TRE bounds from it.
    func header(bbox: (minLat: Double, minLon: Double,
                       maxLat: Double, maxLon: Double)? = nil) {
        var block = ProtoWriter()
        if let bbox {
            // The four corners are sint64: zigzag on the wire, unlike most of the format.
            block.message(Field.headerBBox) { box in
                box.zigzagField(Field.bboxLeft, Self.nanodegrees(bbox.minLon))
                box.zigzagField(Field.bboxRight, Self.nanodegrees(bbox.maxLon))
                box.zigzagField(Field.bboxTop, Self.nanodegrees(bbox.maxLat))
                box.zigzagField(Field.bboxBottom, Self.nanodegrees(bbox.minLat))
            }
        }
        block.stringField(Field.headerRequiredFeature, "OsmSchema-V0.6")
        block.stringField(Field.headerRequiredFeature, "DenseNodes")
        block.stringField(Field.headerWritingProgram, "kmap")
        let payload = block.bytes
        submit { [self] in emit(kind: "OSMHeader", payload: payload) }
    }

    private static func nanodegrees(_ degrees: Double) -> Int64 {
        Int64((degrees * bboxScale).rounded())
    }

    /// Writes nodes dense: ids and coordinates delta-encoded, tags in one flat run.
    func nodes(_ batch: [Node]) {
        guard !batch.isEmpty else { return }
        submit { [self] in
            // Ascending ids, as the delta encoding and readers require.
            let ordered = batch.sorted { $0.id < $1.id }
            for start in stride(from: 0, to: ordered.count, by: Self.maxElementsPerBlock) {
                writeNodeBlock(
                    ordered[start..<min(start + Self.maxElementsPerBlock, ordered.count)])
            }
        }
    }

    private func writeNodeBlock(_ batch: ArraySlice<Node>) {
        var strings = StringTable()
        var ids = ProtoWriter(), lats = ProtoWriter(), lons = ProtoWriter()
        var tags = ProtoWriter()
        // A deliberate underestimate: the buffers grow from here rather than from zero.
        ids.reserve(batch.count * 2)
        lats.reserve(batch.count * 3)
        lons.reserve(batch.count * 3)
        tags.reserve(batch.count)
        var lastID: Int64 = 0, lastLat: Int64 = 0, lastLon: Int64 = 0
        for node in batch {
            let lat = Int64((node.lat * Self.coordinateScale).rounded())
            let lon = Int64((node.lon * Self.coordinateScale).rounded())
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
        dense.bytesField(Field.denseID, ids.bytes)
        dense.bytesField(Field.denseLat, lats.bytes)
        dense.bytesField(Field.denseLon, lons.bytes)
        dense.bytesField(Field.denseKeysVals, tags.bytes)
        emitBlock(strings: strings) { $0.bytesField(Field.groupDense, dense.bytes) }
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
            body.reserve(keys.bytes.count + values.bytes.count + refs.bytes.count + 32)
            body.varintField(Field.elementID, way.id)
            if !keys.bytes.isEmpty {
                body.bytesField(Field.elementKeys, keys.bytes)
                body.bytesField(Field.elementVals, values.bytes)
            }
            body.bytesField(Field.wayRefs, refs.bytes)
            bodies.append(body.bytes)
        }
        emitBlock(strings: strings) { group in
            for body in bodies { group.bytesField(Field.groupWays, body) }
        }
    }

    /// Writes relations, one per group entry. Members are three parallel packed runs:
    /// roles as string-table indices, ids delta-encoded, kinds as the 0/1/2 enum.
    func relations(_ batch: [Relation]) {
        guard !batch.isEmpty else { return }
        submit { [self] in
            for start in stride(from: 0, to: batch.count, by: Self.maxElementsPerBlock) {
                writeRelationBlock(
                    batch[start..<min(start + Self.maxElementsPerBlock, batch.count)])
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
            body.varintField(Field.elementID, relation.id)
            if !keys.bytes.isEmpty {
                body.bytesField(Field.elementKeys, keys.bytes)
                body.bytesField(Field.elementVals, values.bytes)
            }
            if !relation.members.isEmpty {
                body.bytesField(Field.memberRoles, roles.bytes)
                body.bytesField(Field.memberIDs, ids.bytes)
                body.bytesField(Field.memberKinds, kinds.bytes)
            }
            bodies.append(body.bytes)
        }
        emitBlock(strings: strings) { group in
            for body in bodies { group.bytesField(Field.groupRelations, body) }
        }
    }

    private func emitBlock(strings: StringTable, _ body: (inout ProtoWriter) -> Void) {
        var group = ProtoWriter()
        body(&group)
        var block = ProtoWriter()
        block.message(Field.stringTable) { table in
            for word in strings.words { table.bytesField(Field.stringEntry, Array(word.utf8)) }
        }
        block.bytesField(Field.primitiveGroup, group.bytes)
        emit(kind: "OSMData", payload: block.bytes)
    }

    private func emit(kind: String, payload: [UInt8]) {
        enqueue(.toCompress(kind: kind, payload: payload))
    }

    // MARK: Compressing a batch at a time

    private func enqueue(_ piece: Piece) {
        pending.append(piece)
        // Batching pays only where the batch is compressed across the cores, which needs
        // this to be the only writer open.
        let batch = Self.live.count > 1 ? 1 : Self.compressionBatch
        if pending.count >= batch { drain() }
    }

    /// Compresses everything waiting, across every core, and appends the results in the
    /// order they were handed over; a PBF's block order is significant.
    private func drain() {
        guard !pending.isEmpty else { return }
        let work = pending
        pending.removeAll(keepingCapacity: true)

        var packed = [[UInt8]](repeating: [], count: work.count)
        if work.count == 1 || Self.live.count > 1 {
            for (index, piece) in work.enumerated() {
                if case .toCompress(_, let payload) = piece {
                    packed[index] = Self.deflate(payload)
                }
            }
        } else {
            packed.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: work.count) { i in
                    if case .toCompress(_, let payload) = work[i] {
                        slots[i] = Self.deflate(payload)
                    }
                }
            }
        }

        for (index, piece) in work.enumerated() {
            switch piece {
            case .copied(let header, let blob):
                appendLength(header.count)
                buffer.append(contentsOf: header)
                buffer.append(contentsOf: blob)
            case .toCompress(let kind, let payload):
                var blob = ProtoWriter()
                if packed[index].isEmpty {
                    // Deflate may decline; the format allows a blob to carry raw bytes.
                    blob.bytesField(Field.blobRaw, payload)
                } else {
                    blob.varintField(Field.blobRawSize, Int64(payload.count))
                    blob.bytesField(Field.blobZlib, packed[index])
                }
                var header = ProtoWriter()
                header.stringField(Field.blobHeaderKind, kind)
                header.varintField(Field.blobHeaderSize, Int64(blob.bytes.count))
                appendLength(header.bytes.count)
                buffer.append(contentsOf: header.bytes)
                buffer.append(contentsOf: blob.bytes)
            }
        }
        if buffer.count >= Self.flushThreshold { flush() }
    }

    private func appendLength(_ length: Int) {
        var big = UInt32(length).bigEndian
        withUnsafeBytes(of: &big) { buffer.append(contentsOf: $0) }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    /// Finishes the file. Nothing may be written afterwards.
    func finish() throws {
        guard !finished else { return }
        finished = true
        // Drained synchronously, so the file is complete on return.
        queue.sync {
            drain()
            flush()
        }
        Self.live.leave()
        try handle.close()
    }

    /// Deflates as a PBF requires: zlib header, body and adler32 tail. Returns an empty
    /// array where zlib declines; the caller then writes the bytes uncompressed.
    private static func deflate(_ payload: [UInt8]) -> [UInt8] {
        Zlib.deflate(payload) ?? []
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
