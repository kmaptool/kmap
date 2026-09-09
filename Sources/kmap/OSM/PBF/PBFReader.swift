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

/// A block's string table. An entry is decoded to a Swift string on first request and
/// cached; the table is held once per block and shared by reference.
final class StringPool {
    private let raw: [UnsafeRawBufferPointer]
    private var made: [String?]

    init(_ raw: [UnsafeRawBufferPointer]) {
        self.raw = raw
        made = [String?](repeating: nil, count: raw.count)
    }

    var count: Int { raw.count }

    func text(_ index: Int) -> String {
        guard index >= 0 && index < raw.count else { return "" }
        if let known = made[index] { return known }
        let word = String(decoding: raw[index], as: UTF8.self)
        made[index] = word
        return word
    }

    /// Returns every entry, decoding those not decoded yet.
    func all() -> [String] {
        (0..<raw.count).map { text($0) }
    }

    /// Returns an entry's raw bytes, for comparison without building a String.
    func bytes(_ index: Int) -> UnsafeRawBufferPointer? {
        guard index >= 0 && index < raw.count else { return nil }
        return raw[index]
    }
}

/// One decoded block's shared context: the strings every element's tags point into, and
/// the fixed-point scaling for its coordinates.
struct OSMBlock {
    var strings = StringPool([])
    var granularity: Int64 = 100
    var latOffset: Int64 = 0
    var lonOffset: Int64 = 0

    func text(_ index: Int) -> String { strings.text(index) }

    // Wrapping arithmetic: a corrupt granularity or offset must give a wrong coordinate
    // rather than trap.
    func latitude(_ raw: Int64) -> Double {
        Self.quantise(latOffset &+ granularity &* raw)
    }

    func longitude(_ raw: Int64) -> Double {
        Self.quantise(lonOffset &+ granularity &* raw)
    }

    /// Rounds nanodegrees to the hundred: 1e-7 of a degree, the grid libosmium keeps its
    /// locations on.
    static func quantise(_ nanodegrees: Int64) -> Double {
        Double(nanodegrees / 100) * 1e-7        // toward zero, as the C++ does
    }
}

/// Which of a block's three kinds of object a sink wants. Groups not asked for are
/// skipped rather than unpacked; the block is inflated either way.
struct OSMParts: OptionSet {
    let rawValue: UInt8
    static let nodes = OSMParts(rawValue: 1)
    static let ways = OSMParts(rawValue: 2)
    static let relations = OSMParts(rawValue: 4)
    static let all: OSMParts = [.nodes, .ways, .relations]
}

protocol OSMSink {
    /// The parts this sink wants. All of them unless it says otherwise.
    var wantedParts: OSMParts { get }

    /// `tags` alternates key and value indices into the block's string table.
    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock)
    /// Ways keep their keys and values in two parallel runs instead.
    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock)
    /// Members arrive as parallel runs of kind (0 node, 1 way, 2 relation), id and role;
    /// the role is a string-table index, as tags are.
    mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                           memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                           keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                           block: OSMBlock)
    /// Reports a group of this kind in the block, whether or not it was asked for.
    mutating func sawGroup(_ part: OSMParts)
    /// The block's string table is ready and its groups are about to be read.
    mutating func begin(_ block: OSMBlock)
}

extension OSMSink {
    var wantedParts: OSMParts { .all }
    mutating func sawGroup(_ part: OSMParts) {}
    mutating func begin(_ block: OSMBlock) {}

    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {}
    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {}
    mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                           memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                           keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                           block: OSMBlock) {}
}

struct PBFReader {
    let url: URL

    /// Field numbers from the OSM PBF schema.
    private enum Field {
        static let blobHeaderKind = 1, blobHeaderSize = 3
        static let blobRaw = 1, blobRawSize = 2, blobZlib = 3
        static let blobLzma = 4, blobLz4 = 6, blobZstd = 7
        static let stringTable = 1, primitiveGroup = 2
        static let granularity = 17, latOffset = 19, lonOffset = 20
        static let headerBBox = 1
        static let bboxLeft = 1, bboxRight = 2, bboxTop = 3, bboxBottom = 4
        static let groupDense = 2, groupWays = 3, groupRelations = 4
        static let denseID = 1, denseLat = 8, denseLon = 9, denseKeysVals = 10
        static let elementID = 1, elementKeys = 2, elementVals = 3
        static let wayRefs = 8
        static let memberRoles = 8, memberIDs = 9, memberKinds = 10
        static let stringEntry = 1
    }

    /// The format's ceiling on one blob's inflated size. A larger claimed size is rejected.
    private static let maxUncompressedBlob = 32 << 20

    /// The shortest thing that could be a zlib stream at all: two header bytes, at least
    /// one of body, and a four-byte adler32.
    private static let smallestZlibStream = 7

    /// Nanodegrees, the unit a header bounding box is written in.
    private static let bboxScale = 1e9

    /// Returns the bounding box the file's header declares, in degrees, or nil if it
    /// declares none. Tile areas are cut inside this box; anything outside is fringe.
    func headerBBox() throws -> (minLat: Double, minLon: Double,
                                 maxLat: Double, maxLon: Double)? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var scratch = [UInt8](repeating: 0, count: 1 << 20)
        return try data.withUnsafeBytes { file -> (Double, Double, Double, Double)? in
            var at = 0
            guard at + 4 <= file.count else { return nil }
            let headerLength = Int(file.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian)
            at += 4
            guard at + headerLength <= file.count else { return nil }
            let header = UnsafeRawBufferPointer(rebasing: file[at..<(at + headerLength)])
            at += headerLength
            let blobHeader = Self.blobHeader(header)
            guard blobHeader.kind == "OSMHeader",
                  at + blobHeader.size <= file.count else { return nil }
            let blob = UnsafeRawBufferPointer(rebasing: file[at..<(at + blobHeader.size)])
            let size = try Self.inflate(blob, into: &scratch)
            return scratch.withUnsafeBytes { payload -> (Double, Double, Double, Double)? in
                var block = ProtoReader(UnsafeRawBufferPointer(rebasing: payload[0..<size]))
                while let field = block.nextField() {
                    guard field.number == Field.headerBBox else {
                        block.skip(wire: field.wire)
                        continue
                    }
                    var box = ProtoReader(block.lengthDelimited())
                    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0
                    while let corner = box.nextField() {
                        let value = Double(box.zigzag()) / Self.bboxScale
                        switch corner.number {
                        case Field.bboxLeft: left = value
                        case Field.bboxRight: right = value
                        case Field.bboxTop: top = value
                        case Field.bboxBottom: bottom = value
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
                    scratches.withUnsafeMutableBufferPointer { slots in
                        sizes.withUnsafeMutableBufferPointer { lengths in
                            failures.withUnsafeMutableBufferPointer { errors in
                                DispatchQueue.concurrentPerform(iterations: blobs.count) { i in
                                    do {
                                        lengths[i] = try Self.inflate(blobs[i], into: &slots[i])
                                    } catch {
                                        errors[i] = error
                                    }
                                }
                            }
                        }
                    }
                    // The first failure in file order, so the error does not depend on
                    // which core finished first.
                    for i in 0..<blobs.count {
                        if let failure = failures[i] {
                            failures = [Error?](repeating: nil, count: width)
                            throw failure
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
                guard kind == "OSMData" else { return }
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
        while at + 4 <= file.count {
            let headerLength = Int(file.loadUnaligned(fromByteOffset: at,
                                                      as: UInt32.self).bigEndian)
            at += 4
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

    /// Decodes batches of blocks across every core, then calls `apply` once per block in
    /// file order. `apply` must empty the sink it is given: the same sinks are reused for
    /// the next batch.
    func readInOrder<Sink: OSMSink>(make: () -> Sink,
                                    apply: (inout Sink) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = Machine.readers

        // Two halves used in turn: one is applied on this thread while the next decodes on
        // the others. Separate objects, so no one array is reached into by two threads.
        let halves = [Half(width: width, make: make), Half(width: width, make: make)]

        try data.withUnsafeBytes { file in
            var blobs: [UnsafeRawBufferPointer] = []
            try Self.forEachBlob(in: file) { _, kind, blob in
                guard kind == "OSMData" else { return }
                blobs.append(blob)
            }
            guard !blobs.isEmpty else { return }
            
            nonisolated(unsafe) let batch = blobs

            let group = DispatchGroup()
            let pool = DispatchQueue.global(qos: .userInitiated)

            /// Decodes one batch of blobs into one half's slots.
            func decode(_ range: Range<Int>, into half: Half<Sink>) {
                group.enter()
                pool.async {
                    half.sinks.withUnsafeMutableBufferPointer { targets in
                        half.scratches.withUnsafeMutableBufferPointer { buffers in
                            half.failures.withUnsafeMutableBufferPointer { errors in
                            half.fieldSets.withUnsafeMutableBufferPointer { fields in
                                nonisolated(unsafe) let targets = targets
                                nonisolated(unsafe) let buffers = buffers
                                nonisolated(unsafe) let errors = errors
                                nonisolated(unsafe) let fields = fields
                                DispatchQueue.concurrentPerform(iterations: range.count) { i in
                                    do {
                                        let size = try Self.inflate(batch[range.lowerBound + i],
                                                                    into: &buffers[i])
                                        try buffers[i].withUnsafeBytes { payload in
                                            try Self.decodeBlock(
                                                UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                                                into: &targets[i], fields: &fields[i])
                                        }
                                    } catch {
                                        errors[i] = error
                                    }
                                }
                            }
                            }
                        }
                    }
                    group.leave()
                }
            }

            var batches: [Range<Int>] = []
            var at = 0
            while at < blobs.count {
                let end = min(at + width, blobs.count)
                batches.append(at..<end)
                at = end
            }

            decode(batches[0], into: halves[0])
            for (index, batch) in batches.enumerated() {
                group.wait()
                let half = halves[index % 2]
                if index + 1 < batches.count {
                    decode(batches[index + 1], into: halves[(index + 1) % 2])
                }
                for i in 0..<batch.count {
                    if let failure = half.failures[i] {
                        half.failures = [Error?](repeating: nil, count: width)
                        group.wait()
                        throw failure
                    }
                    try apply(&half.sinks[i])
                }
            }
            group.wait()
        }
    }

    /// One half of the in-order reader's double buffer: the sinks a batch decodes into and
    /// the buffers it decodes with. One slot is touched by one worker at a time and one
    /// half by one thread at a time, so the arrays need no lock. The buffers are kept for
    /// the whole file rather than made per block.
    private final class Half<Sink: OSMSink> {
        var sinks: [Sink]
        var scratches: [[UInt8]]
        var failures: [Error?]
        var fieldSets: [Scratch]

        init(width: Int, make: () -> Sink) {
            sinks = (0..<width).map { _ in make() }
            scratches = [[UInt8]](repeating: [], count: width)
            failures = [Error?](repeating: nil, count: width)
            fieldSets = (0..<width).map { _ in Scratch() }
        }
    }


    /// Reads the file with one sink per worker and returns them for the caller to combine.
    /// Only for order-independent work: each worker takes a contiguous run of blocks, so
    /// merging the sinks in worker order reproduces the file's own order.
    func readConcurrently<Sink: OSMSink>(workers: Int = 0,
                                         make: () -> Sink) throws -> [Sink] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = workers > 0 ? workers
            : Machine.readers

        var sinks = (0..<width).map { _ in make() }
        var failures = [Error?](repeating: nil, count: width)
        try data.withUnsafeBytes { file in
            var blobs: [UnsafeRawBufferPointer] = []
            try Self.forEachBlob(in: file) { _, kind, blob in
                guard kind == "OSMData" else { return }
                blobs.append(blob)
            }
            guard !blobs.isEmpty else { return }
            let share = (blobs.count + width - 1) / width

            sinks.withUnsafeMutableBufferPointer { targets in
                failures.withUnsafeMutableBufferPointer { errors in
                    DispatchQueue.concurrentPerform(iterations: width) { worker in
                        let from = worker * share
                        let to = min(from + share, blobs.count)
                        guard from < to else { return }
                        var scratch = [UInt8]()
                        var fields = Scratch()
                        do {
                            for index in from..<to {
                                let size = try Self.inflate(blobs[index], into: &scratch)
                                try scratch.withUnsafeBytes { payload in
                                    try Self.decodeBlock(
                                        UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                                        into: &targets[worker], fields: &fields)
                                }
                            }
                        } catch {
                            errors[worker] = error
                        }
                    }
                }
            }
            for case let failure? in failures { throw failure }
        }
        return sinks
    }

    /// Returns a BlobHeader's kind and payload length. The length is clamped so it can be
    /// added to an offset without trapping; the caller checks it against the file.
    private static func blobHeader(_ bytes: UnsafeRawBufferPointer) -> (kind: String, size: Int) {
        var kind = ""
        var size = 0
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.blobHeaderKind:
                kind = String(decoding: reader.lengthDelimited(), as: UTF8.self)
            case Field.blobHeaderSize:
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
            case Field.blobRaw: raw = reader.lengthDelimited()
            case Field.blobRawSize: plainSize = Int(clamping: reader.varint())
            case Field.blobZlib: zlib = reader.lengthDelimited()
            case Field.blobLzma: throw PBFError.unsupportedCompression("lzma")
            case Field.blobLz4: throw PBFError.unsupportedCompression("lz4")
            case Field.blobZstd: throw PBFError.unsupportedCompression("zstd")
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
        guard plainSize <= maxUncompressedBlob else {
            throw PBFError.truncated("a blob claiming \(plainSize / (1 << 20)) MB, past the format's 32")
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

    /// Decode buffers, filled and refilled block by block. One set per thread, never
    /// shared: the concurrent readers each make their own.
    struct Scratch {
        var refs = [Int64](), keys = [Int32](), values = [Int32]()
        var ids = [Int64](), lats = [Int64](), lons = [Int64](), tags = [Int32]()
        var roles = [Int32](), kinds = [Int32]()
    }

    /// Decodes one inflated PrimitiveBlock into a sink. The same decoder serves every pass
    /// and the rewriter, so they cannot disagree about deltas, tag runs or coordinates.
    static func decodeBlock<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, into sink: inout Sink,
                                           fields: inout Scratch) throws {
        var block = OSMBlock()
        var words: [UnsafeRawBufferPointer] = []
        var groups: [UnsafeRawBufferPointer] = []
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.stringTable:
                var table = ProtoReader(reader.lengthDelimited())
                while let entry = table.nextField() {
                    if entry.number == Field.stringEntry {
                        words.append(table.lengthDelimited())
                    } else {
                        table.skip(wire: entry.wire)
                    }
                }
            case Field.primitiveGroup: groups.append(reader.lengthDelimited())
            // Bit patterns, not range-checked conversions: a corrupt value must give a
            // wrong coordinate rather than trap.
            case Field.granularity: block.granularity = Int64(bitPattern: reader.varint())
            case Field.latOffset: block.latOffset = Int64(bitPattern: reader.varint())
            case Field.lonOffset: block.lonOffset = Int64(bitPattern: reader.varint())
            default: reader.skip(wire: field.wire)
            }
        }

        block.strings = StringPool(words)
        sink.begin(block)
        let wanted = sink.wantedParts
        for group in groups {
            var reader = ProtoReader(group)
            while let field = reader.nextField() {
                switch field.number {
                case Field.groupDense:
                    sink.sawGroup(.nodes)
                    guard wanted.contains(.nodes) else { reader.skip(wire: field.wire); break }
                    decodeDense(reader.lengthDelimited(), block: block, into: &sink,
                                fields: &fields)
                case Field.groupWays:
                    sink.sawGroup(.ways)
                    guard wanted.contains(.ways) else { reader.skip(wire: field.wire); break }
                    decodeWay(reader.lengthDelimited(), block: block, into: &sink,
                              fields: &fields)
                case Field.groupRelations:
                    sink.sawGroup(.relations)
                    guard wanted.contains(.relations) else { reader.skip(wire: field.wire); break }
                    decodeRelation(reader.lengthDelimited(), block: block, into: &sink,
                                   fields: &fields)
                default: reader.skip(wire: field.wire)
                }
            }
        }
    }

    /// Dense nodes are packed and delta-encoded, with every node's tags in one flat run of
    /// key/value indices, each node's run closed by a zero.
    private static func decodeDense<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, block: OSMBlock,
                                            into sink: inout Sink,
                                            fields: inout Scratch) {
        fields.ids.removeAll(keepingCapacity: true)
        fields.lats.removeAll(keepingCapacity: true)
        fields.lons.removeAll(keepingCapacity: true)
        fields.tags.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.denseID: Self.packedZigzag(reader.lengthDelimited(), into: &fields.ids)
            case Field.denseLat: Self.packedZigzag(reader.lengthDelimited(), into: &fields.lats)
            case Field.denseLon: Self.packedZigzag(reader.lengthDelimited(), into: &fields.lons)
            case Field.denseKeysVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.tags)
            default: reader.skip(wire: field.wire)
            }
        }
        // Local names for the scratch buffers; no copy is made.
        let ids = fields.ids, lats = fields.lats, lons = fields.lons, tags = fields.tags

        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, cursor = 0
        for i in 0..<ids.count {
            // Wrapping: deltas summing past Int64.max in a corrupt file must give a wrong
            // node rather than trap.
            id &+= ids[i]
            lat &+= i < lats.count ? lats[i] : 0
            lon &+= i < lons.count ? lons[i] : 0
            // A pair needs both halves: stepping on a lone trailing key would run the
            // cursor past the end and trap on the slice below.
            let start = cursor
            while cursor + 1 < tags.count && tags[cursor] != 0 { cursor += 2 }
            let end = min(cursor, tags.count)
            if cursor < tags.count { cursor += 1 }              // step over the terminator
            sink.node(id: id, lat: block.latitude(lat), lon: block.longitude(lon),
                      tags: tags[start..<end], block: block)
        }
    }

    private static func decodeWay<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, block: OSMBlock,
                                          into sink: inout Sink, fields: inout Scratch) {
        var id: Int64 = 0
        // Emptied, not replaced: assigning a new array would discard the kept capacity.
        fields.refs.removeAll(keepingCapacity: true)
        fields.keys.removeAll(keepingCapacity: true)
        fields.values.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.elementID: id = Int64(bitPattern: reader.varint())
            case Field.elementKeys:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.keys)
            case Field.elementVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.values)
            case Field.wayRefs:
                var delta: Int64 = 0
                var packed = ProtoReader(reader.lengthDelimited())
                while !packed.isAtEnd {
                    delta &+= packed.zigzag()
                    fields.refs.append(delta)
                }
            default: reader.skip(wire: field.wire)
            }
        }
        sink.way(id: id, refs: fields.refs[...], keys: fields.keys[...],
                 values: fields.values[...], block: block)
    }

    private static func decodeRelation<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer,
                                               block: OSMBlock, into sink: inout Sink,
                                               fields: inout Scratch) {
        var id: Int64 = 0
        fields.refs.removeAll(keepingCapacity: true)
        fields.keys.removeAll(keepingCapacity: true)
        fields.values.removeAll(keepingCapacity: true)
        fields.kinds.removeAll(keepingCapacity: true)
        fields.roles.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.elementID: id = Int64(bitPattern: reader.varint())
            case Field.elementKeys:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.keys)
            case Field.elementVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.values)
            case Field.memberRoles:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.roles)
            case Field.memberIDs:
                var delta: Int64 = 0
                var packed = ProtoReader(reader.lengthDelimited())
                while !packed.isAtEnd {
                    delta &+= packed.zigzag()
                    fields.refs.append(delta)
                }
            case Field.memberKinds:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.kinds)
            default: reader.skip(wire: field.wire)
            }
        }
        sink.relation(id: id, memberKinds: fields.kinds[...], memberIDs: fields.refs[...],
                      memberRoles: fields.roles[...], keys: fields.keys[...],
                      values: fields.values[...], block: block)
    }

    /// Appends into a buffer the caller owns and keeps. The reserve is half the byte
    /// count, these streams averaging near two bytes per varint; a buffer needing more
    /// grows once and stays grown.
    static func packedZigzag(_ bytes: UnsafeRawBufferPointer, into out: inout [Int64]) {
        if out.capacity < bytes.count / 2 { out.reserveCapacity(bytes.count / 2) }
        var reader = ProtoReader(bytes)
        while !reader.isAtEnd { out.append(reader.zigzag()) }
    }

    static func packedVarint32(_ bytes: UnsafeRawBufferPointer, into out: inout [Int32]) {
        if out.capacity < bytes.count / 2 { out.reserveCapacity(bytes.count / 2) }
        var reader = ProtoReader(bytes)
        while !reader.isAtEnd { out.append(Int32(truncatingIfNeeded: reader.varint())) }
    }
}

extension ArraySlice {
    /// A copy holding exactly these elements, with capacity to match. `Array(slice)` may
    /// instead hand back the source buffer, carrying a scratch array's full grown
    /// capacity.
    var exactly: [Element] {
        [Element](unsafeUninitializedCapacity: count) { out, made in
            _ = out.initialize(fromContentsOf: self)
            made = count
        }
    }
}
