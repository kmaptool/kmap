import Foundation

/// GEDTM30 v1.2 (OpenGeoHub): bare-earth terrain at 1 arc-second, 65S to 85N. CC BY 4.0.
///
/// 1 BigTIFF of 432 GB, read by HTTP range: the header, the index entries and the tiles
/// the cells need. Pixel centres sit on whole arc-seconds, so a node is a pixel. Values
/// are metres despite the SCALE 0.1 metadata.
struct GEDTM30: DEMSource {
    static let v12 = GEDTM30(
        url: URL(
            string: "https://s3.opengeohub.org/global/dtm/v1.2/"
                + "gedtm_rf_m_30m_s_20060101_20151231_go_epsg.4326.3855_v1.2.tif"
        )!
    )

    let url: URL
    /// Names the absence marks, so a newer edition is asked afresh.
    var edition = "v1.2"
    let sourceID = "gedtm1"
    let directoryName = "GED1"
    /// Settable for tests.
    var nodes = 3601
    let label = "GEDTM30"
    let credits = ["GEDTM30: OpenGeoHub, CC BY 4.0"]

    /// Fetched tiles awaiting conversion, as served. Named by position in the file, so a
    /// newer edition never reuses a stale chunk.
    var chunkDirectory: URL { Paths.cache.appendingPathComponent("gedtm-tiles", isDirectory: true) }

    func chunk(_ span: Span) -> URL {
        chunkDirectory.appendingPathComponent("\(span.offset)-\(span.count).deflate")
    }

    /// Marks an all-sea cell so a rebuild skips it; later sources may still fill it.
    func seaMark(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).\(edition).sea")
    }

    /// Marks a cell the raster does not hold whole (85N, 65S); later sources may fill it.
    func outsideMark(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).\(edition).out")
    }

    /// Leaves `mark`, removing the edition-less mark of 1.7.0.
    func leave(_ mark: URL) throws {
        try FileTools.write(Data(), to: mark)
        let name = mark.lastPathComponent
        guard let cell = name.split(separator: ".").first, name.hasSuffix(".sea") else { return }
        FileTools.removeIfPresent(mark.deletingLastPathComponent().appendingPathComponent("\(cell).sea"))
    }

    /// Whether the cell is known to be sea or outside the raster.
    func holdsNothing(lat: Int, lon: Int) -> Bool {
        FileTools.exists(seaMark(lat: lat, lon: lon)) || FileTools.exists(outsideMark(lat: lat, lon: lon))
    }

    /// Whether the cell needs nothing more from this source.
    func isDone(lat: Int, lon: Int) -> Bool {
        FileTools.exists(cachedTile(lat: lat, lon: lon)) || holdsNothing(lat: lat, lon: lon)
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case notTIFF
        case unsupported(String)
        case truncated

        var description: String {
            switch self {
            case .notTIFF: "not a TIFF file"
            case .unsupported(let what): "unsupported GEDTM30 layout: \(what)"
            case .truncated: "a GEDTM30 tile ends early"
            }
        }

        var errorDescription: String? { description }
    }

    /// Bytes `offset..<offset + count` of the file.
    typealias Read = @Sendable (_ offset: Int64, _ count: Int) async throws -> Data

    /// HTTP reads via a part file, so a 200 for the whole file is refused before its body.
    /// Reads are kept for the run: estimates and builds ask for the same header and index.
    func remote() -> Read {
        let url = url
        return { offset, count in
            let key = ReadKey(url: url, offset: offset, count: count)
            if let known = Self.readsKept.withLock({ $0.data[key] }) { return known }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kmap-gedtm-\(UUID().uuidString)")
            // A failed or stopped read leaves its part file.
            defer {
                FileTools.removeIfPresent(file)
                FileTools.removeIfPresent(PartFiles(destination: file).part(0))
            }
            try await Downloader(log: Log()).download(url: url, from: offset, count: Int64(count), to: file)
            let data = try Data(contentsOf: file)
            Self.readsKept.withLock { $0.keep(data, for: key) }
            return data
        }
    }

    private struct ReadKey: Hashable {
        let url: URL
        let offset: Int64
        let count: Int
    }

    /// Up to `mostKept` bytes; past that nothing more is kept.
    private struct ReadsKept {
        var data: [ReadKey: Data] = [:]
        var bytes = 0

        mutating func keep(_ read: Data, for key: ReadKey) {
            guard data[key] == nil, bytes + read.count <= GEDTM30.mostKept else { return }
            data[key] = read
            bytes += read.count
        }
    }

    private static let mostKept = 32 << 20
    private static let readsKept = Locked(ReadsKept())

    /// Forgets the kept reads if parsing fails, so a bad read is not served again.
    static func parsing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            // Any failure: a bad header can also send the next read past the end of the file.
            readsKept.withLock { $0 = ReadsKept() }
            throw error
        }
    }

    /// For the tests.
    static var keptReads: Int { readsKept.withLock { $0.data.count } }
}

// MARK: The layout

extension GEDTM30 {
    /// What the first image of the file says about itself, and where its tile index is.
    struct Layout: Sendable {
        let width: Int
        let height: Int
        let tileWidth: Int
        let tileHeight: Int
        let bigEndian: Bool
        let predictor: Int
        let offsetsAt: Int64
        let offsetSize: Int
        let countsAt: Int64
        let countSize: Int
        let tileCount: Int
        /// Where the centre of pixel (0, 0) is, and the pixel size, in degrees.
        let firstLon: Double
        let firstLat: Double
        let step: Double
        let nodata: Float?

        var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
        var tileBytes: Int { tileWidth * tileHeight * 4 }

        /// The pixel holding the cell's north-west node. Nodes go 1 pixel per arc-second
        /// from there, east and south.
        func corner(lat: Int, lon: Int) throws -> (row: Int, column: Int) {
            let column = (Double(lon) - firstLon) / step
            let row = (firstLat - Double(lat + 1)) / step
            guard abs(column - column.rounded()) < 0.01, abs(row - row.rounded()) < 0.01 else {
                throw Trouble.unsupported("pixel centres off the arc-second grid")
            }
            return (Int(row.rounded()), Int(column.rounded()))
        }

        /// The tiles a cell's nodes fall in, row by row of tiles. None unless the raster
        /// holds every node: a cell cut by its edge (85N, 65S) is left to later sources.
        func tiles(lat: Int, lon: Int, nodes: Int) throws -> [Int] {
            let (row, column) = try corner(lat: lat, lon: lon)
            guard row >= 0, column >= 0, row + nodes <= height, column + nodes <= width else { return [] }
            var out: [Int] = []
            for tileRow in (row / tileHeight)...((row + nodes - 1) / tileHeight) {
                for tileColumn in (column / tileWidth)...((column + nodes - 1) / tileWidth) {
                    out.append(tileRow * tilesAcross + tileColumn)
                }
            }
            return out
        }
    }

    /// Reads the header and the first image's tags, BigTIFF or classic.
    static func layout(read: Read) async throws -> Layout {
        let head = try await read(0, 16)
        guard head.count >= 16 else { throw Trouble.notTIFF }
        let bigEndian: Bool
        switch (head[0], head[1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: throw Trouble.notTIFF
        }
        let bytes = Bytes(bigEndian: bigEndian)
        let version = bytes.int(head, 2, 2)
        guard version == 42 || version == 43 else { throw Trouble.notTIFF }
        let big = version == 43
        let ifd = Int64(big ? bytes.int(head, 8, 8) : bytes.int(head, 4, 4))
        let countSize = big ? 8 : 2, entrySize = big ? 20 : 12, fieldSize = big ? 8 : 4
        let entries = bytes.int(try await read(ifd, countSize), 0, countSize)
        guard entries > 0, entries < 1000 else { throw Trouble.notTIFF }
        let table = try await read(ifd + Int64(countSize), entries * entrySize)
        guard table.count == entries * entrySize else { throw Trouble.notTIFF }

        // Each tag as its type, count, and the field holding the value or its offset.
        var tags: [Int: (type: Int, count: Int, field: Int)] = [:]
        for i in 0..<entries {
            let at = i * entrySize
            let count = bytes.int(table, at + 4, big ? 8 : 4)
            tags[bytes.int(table, at, 2)] = (bytes.int(table, at + 2, 2), count, at + (big ? 12 : 8))
        }
        func size(_ type: Int) -> Int {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11: 4
            default: 8
            }
        }
        // The value's bytes, inline or fetched from where the field points.
        func raw(_ tag: Int) async throws -> (type: Int, count: Int, data: Data)? {
            guard let entry = tags[tag] else { return nil }
            // Tags read whole are short; a huge count means a damaged header.
            guard entry.count >= 0, entry.count <= 65536 else { throw Trouble.notTIFF }
            let length = size(entry.type) * entry.count
            if length <= fieldSize {
                return (entry.type, entry.count, table.subdata(in: entry.field..<(entry.field + length)))
            }
            let at = Int64(bytes.int(table, entry.field, fieldSize))
            return (entry.type, entry.count, try await read(at, length))
        }
        func numbers(_ tag: Int) async throws -> [Double] {
            guard let (type, count, data) = try await raw(tag) else { return [] }
            let width = size(type)
            guard data.count >= width * count else { throw Trouble.notTIFF }
            return (0..<count).map { i in
                switch type {
                case 11: Double(Float(bitPattern: UInt32(truncatingIfNeeded: bytes.word(data, i * 4, 4))))
                case 12: Double(bitPattern: bytes.word(data, i * 8, 8))
                default: Double(bytes.int(data, i * width, width))
                }
            }
        }
        func one(_ tag: Int, _ fallback: Int? = nil) async throws -> Int {
            if let value = try await numbers(tag).first {
                guard let whole = Int(exactly: value) else { throw Trouble.notTIFF }
                return whole
            }
            guard let fallback else { throw Trouble.unsupported("no tag \(tag)") }
            return fallback
        }
        // The tile index is too long to fetch whole: only where it starts is wanted.
        func array(_ tag: Int) throws -> (at: Int64, size: Int, count: Int) {
            guard let entry = tags[tag], entry.type == 4 || entry.type == 16 else {
                throw Trouble.unsupported("tile index tag \(tag)")
            }
            let width = size(entry.type)
            guard entry.count > 1, entry.count <= 1 << 24 else { throw Trouble.unsupported("tile count") }
            return (Int64(bytes.int(table, entry.field, fieldSize)), width, entry.count)
        }

        let compression = try await one(259)
        guard compression == 8 || compression == 32946 else { throw Trouble.unsupported("compression") }
        guard try await one(258) == 32, try await one(339, 1) == 3 else {
            throw Trouble.unsupported("samples other than float32")
        }
        guard try await one(277, 1) == 1 else { throw Trouble.unsupported("several bands") }
        let predictor = try await one(317, 1)
        guard predictor == 1 || predictor == 2 else { throw Trouble.unsupported("predictor \(predictor)") }
        let offsets = try array(324), counts = try array(325)
        guard offsets.count == counts.count else { throw Trouble.notTIFF }

        let scale = try await numbers(33550), tie = try await numbers(33922)
        guard scale.count >= 2, tie.count >= 6, scale[0] > 0, abs(scale[0] - scale[1]) < 1e-12,
            abs(scale[0] * 3600 - 1) < 1e-6
        else { throw Trouble.unsupported("not 1 arc-second") }
        // GeoKey 1025 (RasterType): 2 places the tiepoint on a pixel's centre, 1 or none on
        // its corner.
        let keys = try await numbers(34735).map { Int(exactly: $0) ?? -1 }
        var isPoint = false
        if keys.count >= 4, keys[3] > 0 {
            for k in 0..<keys[3] where 4 + 4 * k + 3 < keys.count && keys[4 + 4 * k] == 1025 {
                isPoint = keys[4 + 4 * k + 3] == 2
            }
        }
        let half = isPoint ? 0 : 0.5
        var nodata: Float?
        if let (_, _, data) = try await raw(42113) {
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            nodata = Float(text.trimmingCharacters(in: .whitespaces))
        }
        let pixel = (tie[0], tie[1])
        let width = try await one(256), height = try await one(257)
        let tileWidth = try await one(322), tileHeight = try await one(323)
        guard width > 0, height > 0, (1...4096).contains(tileWidth), (1...4096).contains(tileHeight),
            offsets.count == ((width + tileWidth - 1) / tileWidth) * ((height + tileHeight - 1) / tileHeight)
        else { throw Trouble.unsupported("tile grid") }
        return Layout(
            width: width,
            height: height,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            bigEndian: bigEndian,
            predictor: predictor,
            offsetsAt: offsets.at,
            offsetSize: offsets.size,
            countsAt: counts.at,
            countSize: counts.size,
            tileCount: offsets.count,
            firstLon: tie[3] + (half - pixel.0) * scale[0],
            firstLat: tie[4] - (half - pixel.1) * scale[1],
            step: scale[0],
            nodata: nodata
        )
    }

    /// Integers out of the file in its own byte order.
    struct Bytes {
        let bigEndian: Bool

        func int(_ data: Data, _ at: Int, _ width: Int) -> Int {
            Int(truncatingIfNeeded: word(data, at, width))
        }

        func word(_ data: Data, _ at: Int, _ width: Int) -> UInt64 {
            var value: UInt64 = 0
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + at
                for i in 0..<width {
                    value = value << 8 | UInt64(base[bigEndian ? i : width - 1 - i])
                }
            }
            return value
        }
    }
}

// MARK: The tiles

extension GEDTM30 {
    /// Where a tile's bytes are, and how many. A tile of 0 bytes is all nodata.
    struct Span: Sendable, Equatable {
        let offset: Int64
        let count: Int
    }

    /// Index entries further apart are read separately, so distant regions do not pull
    /// the index between them.
    static let indexGap = 64

    /// A longer span means a damaged index.
    static let largestSpan = 64 << 20

    /// Spans of these tiles, from the index in runs of nearby entries, 6 runs at a time.
    static func spans(of tiles: Set<Int>, in layout: Layout, read: @escaping Read) async throws -> [Int: Span] {
        let bytes = Bytes(bigEndian: layout.bigEndian)
        let runs = runs(of: tiles.filter { $0 >= 0 && $0 < layout.tileCount })
        let out = Locked<[Int: Span]>([:])
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let run = runs[next]
                next += 1
                group.addTask {
                    let first = run[0], span = run[run.count - 1] - first + 1
                    async let offsets = read(
                        layout.offsetsAt + Int64(first * layout.offsetSize),
                        span * layout.offsetSize
                    )
                    async let counts = read(layout.countsAt + Int64(first * layout.countSize), span * layout.countSize)
                    let (o, c) = try await (offsets, counts)
                    guard o.count == span * layout.offsetSize, c.count == span * layout.countSize else {
                        throw Trouble.truncated
                    }
                    var found: [Int: Span] = [:]
                    for tile in run {
                        let k = tile - first
                        let offset = bytes.int(o, k * layout.offsetSize, layout.offsetSize)
                        let count = bytes.int(c, k * layout.countSize, layout.countSize)
                        guard offset >= 0, (0...largestSpan).contains(count) else { throw Trouble.notTIFF }
                        found[tile] = Span(offset: Int64(offset), count: count)
                    }
                    out.withLock { $0.merge(found) { a, _ in a } }
                }
            }
            while next < runs.count && next < 6 { launch() }
            for try await _ in group where next < runs.count { launch() }
        }
        return out.withLock { $0 }
    }

    /// The tiles sorted and cut wherever 2 neighbours are more than `indexGap` apart.
    static func runs(of tiles: Set<Int>) -> [[Int]] {
        var out: [[Int]] = []
        for tile in tiles.sorted() {
            if let last = out.last?.last, tile - last <= indexGap {
                out[out.count - 1].append(tile)
            } else {
                out.append([tile])
            }
        }
        return out
    }

    /// A tile's samples from its bytes as served: inflated, the predictor undone.
    static func decode(_ compressed: Data, layout: Layout) throws -> [Float] {
        let count = layout.tileWidth * layout.tileHeight
        var raw = [UInt8](unsafeUninitializedCapacity: layout.tileBytes) { _, filled in filled = layout.tileBytes }
        do {
            try compressed.withUnsafeBytes { input in
                try raw.withUnsafeMutableBufferPointer { out in
                    try Deflate.inflate(input, into: out, expecting: layout.tileBytes)
                }
            }
        } catch {
            throw Trouble.truncated
        }
        return [Float](unsafeUninitializedCapacity: count) { out, filled in
            filled = count
            raw.withUnsafeMutableBufferPointer { bytes in
                GeoTIFF.wordRows(
                    bytes.baseAddress!,
                    width: layout.tileWidth,
                    rows: layout.tileHeight,
                    bigEndian: layout.bigEndian,
                    differenced: layout.predictor == 2,
                    into: out.baseAddress!
                )
            }
        }
    }

    /// Writes 1 cell as `.hgt`, a node per pixel. `sample` yields a decoded tile, nil for
    /// all nodata. Returns the ground nodes; 0 is sea, and nothing is written.
    func write(
        lat: Int,
        lon: Int,
        layout: Layout,
        to url: URL,
        sample: (Int) throws -> [Float]?
    ) throws -> Int {
        let n = nodes
        let (row0, column0) = try layout.corner(lat: lat, lon: lon)
        var out = [UInt8](repeating: 0, count: n * n * 2)
        var ground = 0
        for tile in try layout.tiles(lat: lat, lon: lon, nodes: n) {
            guard let samples = try sample(tile) else { continue }
            let top = tile / layout.tilesAcross * layout.tileHeight
            let left = tile % layout.tilesAcross * layout.tileWidth
            // The part of the cell this tile holds, in cell nodes.
            let firstRow = max(0, top - row0), lastRow = min(n - 1, top + layout.tileHeight - 1 - row0)
            let firstColumn = max(0, left - column0)
            let lastColumn = min(n - 1, left + layout.tileWidth - 1 - column0)
            guard firstRow <= lastRow, firstColumn <= lastColumn else { continue }
            samples.withUnsafeBufferPointer { samples in
                out.withUnsafeMutableBufferPointer { out in
                    for r in firstRow...lastRow {
                        let line = samples.baseAddress! + (row0 + r - top) * layout.tileWidth + (column0 - left)
                        ground += HGTConversion.storeHeights(
                            line + firstColumn,
                            count: lastColumn - firstColumn + 1,
                            nodata: layout.nodata,
                            into: out.baseAddress! + (r * n + firstColumn) * 2
                        )
                    }
                }
            }
        }
        guard ground > 0 else { return 0 }
        try FileTools.write(Data(out), to: url)
        return ground
    }
}
