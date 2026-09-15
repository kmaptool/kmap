import Foundation

/// Errors raised while reading an OSM PBF.
enum PBFError: Error, CustomStringConvertible, LocalizedError {
    case truncated(String)
    case unsupportedCompression(String)

    var description: String {
        switch self {
        case .truncated(let what): return "the file ends in the middle of \(what)"
        case .unsupportedCompression(let how): return "blob compressed with \(how), which this reader does not do"
        }
    }
}

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

    /// The shortest thing that could be a zlib stream at all: two header bytes, at least
    /// one of body, and a four-byte adler32.
    private static let smallestZlibStream = 7

    /// Returns the bounding box the file's header declares, in degrees, or nil if it
    /// declares none. Tile areas are cut inside this box; anything outside is fringe.
    func headerBBox() throws -> (minLat: Double, minLon: Double,
                                 maxLat: Double, maxLon: Double)? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var scratch = [UInt8](repeating: 0, count: Self.megabyte)
        return try data.withUnsafeBytes { file -> (Double, Double, Double, Double)? in
            var at = 0
            guard at + PBFSchema.lengthPrefix <= file.count else { return nil }
            let headerLength = Int(file.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian)
            at += PBFSchema.lengthPrefix
            guard at + headerLength <= file.count else { return nil }
            let header = UnsafeRawBufferPointer(rebasing: file[at..<(at + headerLength)])
            at += headerLength
            let blobHeader = Self.blobHeader(header)
            guard blobHeader.kind == PBFSchema.headerBlob,
                  at + blobHeader.size <= file.count else { return nil }
            let blob = UnsafeRawBufferPointer(rebasing: file[at..<(at + blobHeader.size)])
            let size = try Self.inflate(blob, into: &scratch)
            return scratch.withUnsafeBytes { payload -> (Double, Double, Double, Double)? in
                var block = ProtoReader(UnsafeRawBufferPointer(rebasing: payload[0..<size]))
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
        }
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
        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            box.extend(lon: lon, lat: lat)
        }
        mutating func way(id: Int64, refs: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                          block: OSMBlock) {}
        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {}
    }

    /// Walks the whole file, handing every node and way to the sink. Blocks are inflated
    /// a batch at a time across every core, then decoded on this thread in file order.
    func read<Sink: OSMSink>(into sink: inout Sink) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var fields = Scratch()

        let width = Machine.readers
        var scratches = [[UInt8]](repeating: [], count: width)
        var sizes = [Int](repeating: 0, count: width)
        var failures = [Error?](repeating: nil, count: width)
        var batch: [UnsafeRawBufferPointer] = []
        batch.reserveCapacity(width)

        try data.withUnsafeBytes { file in
            /// Inflates everything waiting, then decodes it in the order read.
            func drain() throws {
                guard !batch.isEmpty else { return }
                let blobs = batch
                if blobs.count == 1 {
                    sizes[0] = try Self.inflate(blobs[0], into: &scratches[0])
                } else {
                    try scratches.withUnsafeMutableBufferPointer { slots in
                        try sizes.withUnsafeMutableBufferPointer { lengths in
                            try Self.acrossCores(blobs.count, failures: &failures) { i in
                                lengths[i] = try Self.inflate(blobs[i], into: &slots[i])
                            }
                        }
                    }
                }
                for i in 0..<blobs.count {
                    let size = sizes[i]
                    try scratches[i].withUnsafeBytes { payload in
                        try Self.decodeBlock(UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                                        into: &sink, fields: &fields)
                    }
                }
                batch.removeAll(keepingCapacity: true)
            }

            try Self.forEachBlob(in: file) { _, kind, blob in
                // The header block holds nothing the sink wants.
                guard kind == PBFSchema.dataBlob else { return }
                if stopped() { throw CancellationError() }
                batch.append(blob)
                if batch.count == width { try drain() }
            }
            try drain()
        }
    }

    /// Walks a mapped PBF's blobs, handing each its header bytes, its kind and its
    /// payload. Every declared length is checked against the file before it slices it.
    static func forEachBlob(
        in file: UnsafeRawBufferPointer,
        _ body: (_ header: UnsafeRawBufferPointer, _ kind: String,
                 _ blob: UnsafeRawBufferPointer) throws -> Void) throws {
        var at = 0
        while at + PBFSchema.lengthPrefix <= file.count {
            let headerLength = Int(file.loadUnaligned(fromByteOffset: at,
                                                      as: UInt32.self).bigEndian)
            at += PBFSchema.lengthPrefix
            guard headerLength >= 0, at + headerLength <= file.count else {
                throw PBFError.truncated("a blob header")
            }
            let header = UnsafeRawBufferPointer(rebasing: file[at..<(at + headerLength)])
            at += headerLength

            let parsed = blobHeader(header)
            guard at + parsed.size <= file.count else { throw PBFError.truncated("a blob") }
            let blob = UnsafeRawBufferPointer(rebasing: file[at..<(at + parsed.size)])
            at += parsed.size
            try body(header, parsed.kind, blob)
        }
    }

    /// Runs `body` for every index across the cores and rethrows the first failure in
    /// index order, so an error does not depend on which core finished first. The
    /// failures array is the caller's, kept across batches, and is cleared on a throw.
    static func acrossCores(_ count: Int, failures: inout [Error?],
                            _ body: (Int) throws -> Void) throws {
        guard count > 0 else { return }
        failures.withUnsafeMutableBufferPointer { errors in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                do { try body(i) } catch { errors[i] = error }
            }
        }
        for i in 0..<count {
            guard let failure = failures[i] else { continue }
            for j in 0..<count { failures[j] = nil }
            throw failure
        }
    }

    /// Returns a BlobHeader's kind and payload length. The length is clamped so it can be
    /// added to an offset without trapping; the caller checks it against the file.
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

    /// Inflates a blob into `scratch`, growing it if needed, and returns the byte count. A
    /// blob is stored raw or zlib-wrapped; a wrapped one is passed to zlib whole, header,
    /// body and checksum, so the checksum is verified.
    static func inflate(_ blob: UnsafeRawBufferPointer,
                        into scratch: inout [UInt8]) throws -> Int {
        var raw: UnsafeRawBufferPointer?
        var zlib: UnsafeRawBufferPointer?
        var plainSize = 0
        var reader = ProtoReader(blob)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.blobRaw: raw = reader.lengthDelimited()
            case PBFSchema.blobRawSize: plainSize = Int(clamping: reader.varint())
            case PBFSchema.blobZlib: zlib = reader.lengthDelimited()
            case PBFSchema.blobLzma: throw PBFError.unsupportedCompression("lzma")
            case PBFSchema.blobLz4: throw PBFError.unsupportedCompression("lz4")
            case PBFSchema.blobZstd: throw PBFError.unsupportedCompression("zstd")
            default: reader.skip(wire: field.wire)
            }
        }
        if let raw {
            if scratch.count < raw.count {
                scratch = [UInt8](repeating: 0, count: raw.count)
            }
            scratch.withUnsafeMutableBufferPointer { out in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(out))
            }
            return raw.count
        }
        guard let zlib, plainSize > 0 else { throw PBFError.truncated("a blob's payload") }
        // Untrusted size: past the format's ceiling it would be allocated as claimed.
        guard plainSize <= PBFSchema.maxUncompressedBlob else {
            throw PBFError.truncated("a blob claiming \(plainSize / megabyte) MB, past the"
                                     + " format's \(PBFSchema.maxUncompressedBlob / megabyte)")
        }
        guard zlib.count >= smallestZlibStream else { throw PBFError.truncated("a compressed blob") }
        if scratch.count < plainSize { scratch = [UInt8](repeating: 0, count: plainSize) }
        do {
            try scratch.withUnsafeMutableBufferPointer { out in
                try Zlib.inflate(zlib, into: UnsafeMutableBufferPointer(rebasing: out[0..<plainSize]),
                                 expecting: plainSize)
            }
        } catch {
            throw PBFError.truncated("a compressed blob")
        }
        return plainSize
    }
}
