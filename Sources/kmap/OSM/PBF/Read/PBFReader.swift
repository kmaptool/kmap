import Foundation

struct PBFReader {
    let url: URL
    /// Asked between blobs on every thread that reads; true ends the read with a
    /// `CancellationError`. A dispatch worker does not see `Task.isCancelled`, so a
    /// caller with a task of its own hands its flag in here.
    var shouldStop: () -> Bool = { false }

    /// On the reading thread the task's own cancellation counts as well.
    // Not private: the parallel readers are a file of their own.
    func stopped() -> Bool { shouldStop() || Task.isCancelled }

    private static let megabyte = 1 << 20

    /// The shortest thing that could be a deflated blob at all: 2 header bytes, at least
    /// 1 of body, and a 4-byte adler32.
    private static let smallestDeflatedBlob = 7

    /// Returns the bounding box the file's header declares, in degrees, or nil if it
    /// declares none. Tile areas are cut inside this box; anything outside is fringe.
    func headerBBox() throws -> (
        minLat: Double, minLon: Double,
        maxLat: Double, maxLon: Double
    )? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var scratch = [UInt8](repeating: 0, count: Self.megabyte)
        return try data.withUnsafeBytes { file -> (Double, Double, Double, Double)? in
            guard let blob = Self.headerBlob(in: file) else { return nil }
            let size = try Self.inflate(blob, into: &scratch)
            return scratch.withUnsafeBytes { payload in
                Self.bbox(inHeaderBlock: UnsafeRawBufferPointer(rebasing: payload[0..<size]))
            }
        }
    }

    /// The file's first blob, when it is the header blob and whole.
    private static func headerBlob(in file: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        var at = 0
        guard at + PBFSchema.lengthPrefix <= file.count else { return nil }
        let headerLength = Int(file.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian)
        at += PBFSchema.lengthPrefix
        guard at + headerLength <= file.count else { return nil }
        let header = blobHeader(UnsafeRawBufferPointer(rebasing: file[at..<(at + headerLength)]))
        at += headerLength
        guard header.kind == PBFSchema.headerBlob, header.size <= file.count - at else { return nil }
        return UnsafeRawBufferPointer(rebasing: file[at..<(at + header.size)])
    }

    /// The box an inflated header block declares, as (bottom, left, top, right).
    private static func bbox(inHeaderBlock bytes: UnsafeRawBufferPointer) -> (Double, Double, Double, Double)? {
        var block = ProtoReader(bytes)
        while let field = block.nextField() {
            guard field.number == PBFSchema.headerBBox else {
                block.skip(wire: field.wire)
                continue
            }
            var box = ProtoReader(block.lengthDelimited())
            var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0
            while let corner = box.nextField() {
                let value = Double(box.zigzag()) / PBFSchema.bboxScale
                switch corner.number {
                case PBFSchema.bboxLeft: left = value
                case PBFSchema.bboxRight: right = value
                case PBFSchema.bboxTop: top = value
                case PBFSchema.bboxBottom: bottom = value
                default: break
                }
            }
            return (bottom, left, top, right)
        }
        return nil
    }

    /// The box this file's nodes fall in, for one whose header carries none; nil where it
    /// holds no node at all. Nodes only: ways and relations are placed by the nodes they
    /// name, so every coordinate is here.
    func nodeBounds() throws -> BBox? {
        var scan = BoundsSink()
        try read(into: &scan)
        return scan.box.isValid ? scan.box : nil
    }

    private struct BoundsSink: OSMSink {
        var box = BBox.empty
        let wantedParts: OSMParts = .nodes
        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            box.extend(lon: lon, lat: lat)
        }
        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {}
        mutating func relation(
            id: Int64,
            memberKinds: ArraySlice<Int32>,
            memberIDs: ArraySlice<Int64>,
            memberRoles: ArraySlice<Int32>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {}
    }

    /// Walks the whole file, handing every node and way to the sink. Blocks are inflated
    /// a batch at a time across every core, then decoded on this thread in file order.
    func read<Sink: OSMSink>(into sink: inout Sink) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = Machine.readers
        var batch = InflatedBatch(width: width)
        var fields = Scratch()
        try data.withUnsafeBytes { file in
            // Only the blobs holding something the sink asks for, once the file is known.
            let (blobs, log) = BlobParts.select(try Self.dataBlobs(in: file), of: url, wanted: sink.wantedParts)
            for first in stride(from: 0, to: blobs.count, by: width) {
                let range = first..<min(first + width, blobs.count)
                // Asked before each blob is taken into the batch, not once a batch.
                for _ in range where stopped() { throw CancellationError() }
                try batch.inflate(blobs[range])
                for i in range {
                    log?.note(i, holds: try batch.decode(i - first, into: &sink, fields: &fields))
                }
            }
            log?.keep()
        }
    }

    /// A batch of blobs inflated side by side, each into a buffer kept for the next batch.
    private struct InflatedBatch {
        private var scratches: [[UInt8]]
        private var sizes: [Int]
        private var failures: [Error?]

        init(width: Int) {
            scratches = [[UInt8]](repeating: [], count: width)
            sizes = [Int](repeating: 0, count: width)
            failures = [Error?](repeating: nil, count: width)
        }

        mutating func inflate(_ blobs: ArraySlice<UnsafeRawBufferPointer>) throws {
            let blobs = Array(blobs)
            // 1 alone is inflated here: a lane would cost more than it does.
            if blobs.count == 1 {
                sizes[0] = try PBFReader.inflate(blobs[0], into: &scratches[0])
                return
            }
            try scratches.withUnsafeMutableBufferPointer { slots in
                try sizes.withUnsafeMutableBufferPointer { lengths in
                    try PBFReader.acrossCores(blobs.count, failures: &failures) { i in
                        lengths[i] = try PBFReader.inflate(blobs[i], into: &slots[i])
                    }
                }
            }
        }

        /// Decodes the `i`th blob of the batch into `sink`.
        func decode<Sink: OSMSink>(_ i: Int, into sink: inout Sink, fields: inout Scratch) throws -> OSMParts {
            let size = sizes[i]
            return try scratches[i].withUnsafeBytes { payload in
                try PBFReader.decodeBlock(
                    UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                    into: &sink,
                    fields: &fields
                )
            }
        }
    }

    /// The file's data blobs, in order; the header blob holds nothing a sink wants.
    static func dataBlobs(in file: UnsafeRawBufferPointer) throws -> [UnsafeRawBufferPointer] {
        var blobs: [UnsafeRawBufferPointer] = []
        try forEachBlob(in: file) { _, kind, blob in
            if kind == PBFSchema.dataBlob {
                blobs.append(blob)
            } else if kind == PBFSchema.headerBlob {
                try refuseUnknownFeatures(inHeader: blob)
            }
        }
        return blobs
    }

    /// The format's own rule: a file naming a required feature its reader does not know
    /// is refused, not read. A history file would otherwise bring back every deleted object.
    static func refuseUnknownFeatures(inHeader blob: UnsafeRawBufferPointer) throws {
        // A header that does not inflate says nothing either way; the data still reads.
        var scratch: [UInt8] = []
        guard let size = try? inflate(blob, into: &scratch) else { return }
        try scratch.withUnsafeBytes { payload in
            var block = ProtoReader(UnsafeRawBufferPointer(rebasing: payload[0..<size]))
            while let field = block.nextField() {
                guard field.number == PBFSchema.headerRequiredFeature, field.wire == 2 else {
                    block.skip(wire: field.wire)
                    continue
                }
                let feature = String(decoding: block.lengthDelimited(), as: UTF8.self)
                if !PBFSchema.requiredFeatures.contains(feature) { throw PBFError.unsupportedFeature(feature) }
            }
        }
    }

    /// Inflates a blob into `scratch` and decodes it into `sink`.
    /// - Returns: every kind of group the block holds.
    static func decode<Sink: OSMSink>(
        _ blob: UnsafeRawBufferPointer,
        into sink: inout Sink,
        scratch: inout [UInt8],
        fields: inout Scratch
    ) throws -> OSMParts {
        let size = try inflate(blob, into: &scratch)
        return try scratch.withUnsafeBytes { payload in
            try decodeBlock(UnsafeRawBufferPointer(rebasing: payload[0..<size]), into: &sink, fields: &fields)
        }
    }

    /// Walks a mapped PBF's blobs, handing each its header bytes, its kind and its
    /// payload. Every declared length is checked against the file before it slices it.
    static func forEachBlob(
        in file: UnsafeRawBufferPointer,
        _ body: (
            _ header: UnsafeRawBufferPointer, _ kind: String,
            _ blob: UnsafeRawBufferPointer
        ) throws -> Void
    ) throws {
        var at = 0
        while at + PBFSchema.lengthPrefix <= file.count {
            let headerLength = Int(
                file.loadUnaligned(
                    fromByteOffset: at,
                    as: UInt32.self
                ).bigEndian
            )
            at += PBFSchema.lengthPrefix
            guard headerLength >= 0, at + headerLength <= file.count else {
                throw PBFError.truncated("a blob header")
            }
            let header = UnsafeRawBufferPointer(rebasing: file[at..<(at + headerLength)])
            at += headerLength

            let parsed = blobHeader(header)
            // Subtracted, not added: a clamped length can be Int.max.
            guard parsed.size <= file.count - at else { throw PBFError.truncated("a blob") }
            let blob = UnsafeRawBufferPointer(rebasing: file[at..<(at + parsed.size)])
            at += parsed.size
            try body(header, parsed.kind, blob)
        }
    }

    /// Runs `body` for every index across the cores and rethrows the first failure in
    /// index order, so an error does not depend on which core finished first. The
    /// failures array is the caller's, kept across batches, and is cleared on a throw.
    static func acrossCores(
        _ count: Int,
        failures: inout [Error?],
        _ body: (Int) throws -> Void
    ) throws {
        guard count > 0 else { return }
        withoutActuallyEscaping(body) { body in
            failures.withUnsafeMutableBufferPointer { errors in
                // Each index writes only its own slot, and `body` is the caller's promise
                // of the same: nothing is shared, which no type can say.
                nonisolated(unsafe) let errors = errors
                nonisolated(unsafe) let body = body
                DispatchQueue.concurrentPerform(iterations: count) { i in
                    do { try body(i) } catch { errors[i] = error }
                }
            }
        }
        for i in 0..<count {
            guard let failure = failures[i] else { continue }
            for j in 0..<count { failures[j] = nil }
            throw failure
        }
    }

    /// Returns a BlobHeader's kind and payload length. The length is clamped to Int and
    /// may be Int.max: the caller compares it against the room left, never adds it.
    private static func blobHeader(_ bytes: UnsafeRawBufferPointer) -> (kind: String, size: Int) {
        var kind = ""
        var size = 0
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.blobHeaderKind:
                kind = String(decoding: reader.lengthDelimited(), as: UTF8.self)
            case PBFSchema.blobHeaderSize:
                size = Int(clamping: reader.varint())
            default: reader.skip(wire: field.wire)
            }
        }
        return (kind, size)
    }

    /// A blob's payload as stored: raw, or deflated with its size once inflated.
    private struct BlobPayload {
        var raw: UnsafeRawBufferPointer?
        var deflated: UnsafeRawBufferPointer?
        var plainSize = 0

        init(_ blob: UnsafeRawBufferPointer) throws {
            var reader = ProtoReader(blob)
            while let field = reader.nextField() {
                switch field.number {
                case PBFSchema.blobRaw: raw = reader.lengthDelimited()
                case PBFSchema.blobRawSize: plainSize = Int(clamping: reader.varint())
                case PBFSchema.blobDeflated: deflated = reader.lengthDelimited()
                case PBFSchema.blobLzma: throw PBFError.unsupportedCompression("lzma")
                case PBFSchema.blobLz4: throw PBFError.unsupportedCompression("lz4")
                case PBFSchema.blobZstd: throw PBFError.unsupportedCompression("zstd")
                default: reader.skip(wire: field.wire)
                }
            }
        }
    }

    /// Inflates a blob into `scratch`, growing it if needed, and returns the byte count. A
    /// blob is stored raw or deflated; a deflated one is inflated whole, header,
    /// body and checksum, so the checksum is verified.
    static func inflate(
        _ blob: UnsafeRawBufferPointer,
        into scratch: inout [UInt8]
    ) throws -> Int {
        let payload = try BlobPayload(blob)
        if let raw = payload.raw {
            if scratch.count < raw.count {
                scratch = [UInt8](repeating: 0, count: raw.count)
            }
            scratch.withUnsafeMutableBufferPointer { out in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(out))
            }
            return raw.count
        }
        let plainSize = payload.plainSize
        guard let deflated = payload.deflated, plainSize > 0 else { throw PBFError.truncated("a blob's payload") }
        try checkDeflated(deflated, claiming: plainSize)
        if scratch.count < plainSize { scratch = [UInt8](repeating: 0, count: plainSize) }
        do {
            try scratch.withUnsafeMutableBufferPointer { out in
                try Deflate.inflate(
                    deflated,
                    into: UnsafeMutableBufferPointer(rebasing: out[0..<plainSize]),
                    expecting: plainSize
                )
            }
        } catch {
            throw PBFError.truncated("a compressed blob")
        }
        return plainSize
    }

    /// Refuses a deflated blob too short to be one, or claiming more than the format allows:
    /// the size is untrusted, and past the ceiling it would be allocated as claimed.
    private static func checkDeflated(_ deflated: UnsafeRawBufferPointer, claiming plainSize: Int) throws {
        guard plainSize <= PBFSchema.maxUncompressedBlob else {
            throw PBFError.truncated(
                "a blob claiming \(plainSize / megabyte) MB, past the"
                    + " format's \(PBFSchema.maxUncompressedBlob / megabyte)"
            )
        }
        guard deflated.count >= smallestDeflatedBlob else { throw PBFError.truncated("a compressed blob") }
    }
}
