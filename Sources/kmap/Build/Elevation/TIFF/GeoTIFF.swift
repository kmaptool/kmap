import Foundation

/// Reads an elevation tile from a GeoTIFF without GDAL. Accepts classic TIFF, 1 band,
/// tiled or stripped, uncompressed, LZW, PackBits or DEFLATE, with the horizontal or
/// floating-point predictor; anything else throws `Trouble.unsupported`. Tiles are decoded
/// on first touch and kept, since a caller reads whole rows.
struct GeoTIFF {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case notTIFF
        case bigTIFF
        case unsupported(String)
        case truncated

        var description: String {
            switch self {
            case .notTIFF: "not a TIFF file"
            case .bigTIFF: "BigTIFF, which this reader does not do"
            case .unsupported(let what): "unsupported GeoTIFF: \(what)"
            case .truncated: "the file ends in the middle of a tile"
            }
        }
    }

    /// A tile past this many samples is refused: the largest published DEM tile is
    /// 3600 x 3600, and a header can claim anything.
    private static let mostSamplesPerTile = 64 * 1024 * 1024

    let width: Int
    let height: Int

    /// Where sample (0, 0) sits. A point-registered file (`GTRasterType = 2`) places its
    /// samples on these positions; an area-registered one describes cells, whose sample sits
    /// half a step inside the stated corner, corrected for here so the grid is always points.
    let originLon: Double
    let originLat: Double
    /// Degrees per column, and per row. The row step is negative: TIFF rows run southwards.
    let stepLon: Double
    let stepLat: Double

    private let data: Data
    /// A strip is a tile as wide as the image.
    private let tile: Block
    private let tilesAcross: Int
    private let offsets: [Int]
    private let counts: [Int]
    private let compression: Int
    /// Strips: the last one may hold only the rows left.
    private let stripped: Bool
    /// Decoded tiles, by index.
    private let decodedTiles = Locked<[Int: [Float]]>([:])

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 8, let bigEndian = TIFF.isBigEndian(data[0], data[1]) else { throw Trouble.notTIFF }
        let order = TIFF.Order(bigEndian: bigEndian)
        let version = order.int(data, 2, 2)
        if version == TIFF.big { throw Trouble.bigTIFF }
        guard version == TIFF.classic else { throw Trouble.notTIFF }

        let tags = try Self.tagDirectory(in: data, order: order)

        // A tag value is a Double; only a finite one in range becomes an Int.
        func whole(_ value: Double) -> Int? {
            value.isFinite && value >= 0 && value < 1e15 ? Int(value) : nil
        }
        func one(_ tag: Int, _ fallback: Int) -> Int {
            tags[tag]?.first.flatMap(whole) ?? fallback
        }
        func all(_ tag: Int) -> [Int] {
            (tags[tag] ?? []).map { whole($0) ?? -1 }
        }

        width = one(TIFF.Tag.imageWidth, 0)
        height = one(TIFF.Tag.imageLength, 0)
        guard width > 0, height > 0 else { throw Trouble.unsupported("no image size") }
        guard one(TIFF.Tag.samplesPerPixel, 1) == 1 else { throw Trouble.unsupported("more than one band") }
        let bitsPerSample = one(TIFF.Tag.bitsPerSample, 32)
        compression = one(TIFF.Tag.compression, TIFF.Compression.none)
        let known = [
            TIFF.Compression.none, TIFF.Compression.lzw, TIFF.Compression.deflate,
            TIFF.Compression.adobeDeflate, TIFF.Compression.packBits
        ]
        guard known.contains(compression) else { throw Trouble.unsupported("compression \(compression)") }
        guard bitsPerSample == 32 || bitsPerSample == 16 else {
            throw Trouble.unsupported("\(bitsPerSample) bits per sample")
        }

        let tileWidth: Int, tileHeight: Int
        if let tw = tags[TIFF.Tag.tileWidth]?.first, let th = tags[TIFF.Tag.tileLength]?.first {
            tileWidth = whole(tw) ?? 0
            tileHeight = whole(th) ?? 0
            offsets = all(TIFF.Tag.tileOffsets)
            counts = all(TIFF.Tag.tileByteCounts)
            stripped = false
        } else {
            // A strip count past the height (some writers put 2^32 - 1) means 1 strip.
            tileWidth = width
            tileHeight = min(one(TIFF.Tag.rowsPerStrip, height), height)
            offsets = all(TIFF.Tag.stripOffsets)
            counts = all(TIFF.Tag.stripByteCounts)
            stripped = true
        }
        guard !offsets.isEmpty, offsets.count == counts.count else {
            throw Trouble.unsupported("no tile offsets")
        }
        // A tile may be wider or taller than the image: the format pads it, and the DEM
        // tiles north of 80 deg are 720 samples wide in tiles of 1024.
        let (samples, overflow) = tileWidth.multipliedReportingOverflow(by: tileHeight)
        guard tileWidth > 0, tileHeight > 0, !overflow, samples <= Self.mostSamplesPerTile else {
            throw Trouble.unsupported("tile geometry \(tileWidth) x \(tileHeight) in \(width) x \(height)")
        }
        tile = Block(
            width: tileWidth,
            height: tileHeight,
            bytesPerSample: bitsPerSample / 8,
            sampleFormat: one(TIFF.Tag.sampleFormat, TIFF.SampleFormat.unsigned),
            predictor: one(TIFF.Tag.predictor, TIFF.Predictor.none),
            bigEndian: bigEndian
        )
        tilesAcross = (width + tileWidth - 1) / tileWidth

        (stepLon, stepLat, originLon, originLat) = try Self.geoPlacement(from: tags)
    }

    /// The IFD: every tag the file carries, each as the numbers it holds. A tag of an
    /// unknown type, or one pointing past the end, is skipped rather than fatal.
    private static func tagDirectory(in data: Data, order: TIFF.Order) throws -> [Int: [Double]] {
        let directory = order.int(data, 4, 4)
        guard directory + 2 <= data.count else { throw Trouble.truncated }
        let entries = order.int(data, directory, 2)

        var tags: [Int: [Double]] = [:]
        for i in 0..<entries {
            let at = directory + 2 + i * 12
            guard at + 12 <= data.count else { throw Trouble.truncated }
            let type = order.int(data, at + 2, 2), count = order.int(data, at + 4, 4)
            let size = TIFF.size(ofType: type)
            guard size > 0 else { continue }
            // A value of up to 4 bytes sits in the entry itself.
            let value = size * count > 4 ? order.int(data, at + 8, 4) : at + 8
            guard value + size * count <= data.count else { continue }
            tags[order.int(data, at, 2)] = (0..<count).compactMap { order.number(data, value + $0 * size, type: type) }
        }
        return tags
    }

    /// Where the raster sits on the ground, from its GeoTIFF keys.
    ///
    /// ModelPixelScale is (x, y, z) with y positive downwards; ModelTiepoint is 6 doubles
    /// whose last 3 are the world position of raster (i, j). Both are required rather
    /// than defaulted: a default would place the tile silently.
    private static func geoPlacement(
        from tags: [Int: [Double]]
    ) throws -> (stepLon: Double, stepLat: Double, originLon: Double, originLat: Double) {
        guard let scale = tags[TIFF.Tag.modelPixelScale], scale.count >= 2,
            let tie = tags[TIFF.Tag.modelTiepoint], tie.count >= 6
        else {
            throw Trouble.unsupported("no geo-referencing")
        }
        var lon = tie[3] - tie[0] * scale[0]
        var lat = tie[4] + tie[1] * scale[1]
        // A file that does not say is taken as point-registered.
        if TIFF.rasterType(in: tags[TIFF.Tag.geoKeyDirectory] ?? []) == TIFF.RasterType.area {
            lon += scale[0] / 2
            lat -= scale[1] / 2
        }
        return (scale[0], -scale[1], lon, lat)
    }

    // MARK: Samples

    /// 1 sample, or nil outside the raster.
    func value(row: Int, column: Int) throws -> Float? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let samples = try decoded((row / tile.height) * tilesAcross + (column / tile.width))
        let inside = (row % tile.height) * tile.width + (column % tile.width)
        guard inside < samples.count else { return nil }
        return samples[inside]
    }

    /// The samples of 1 raster row, left to right, or empty outside the raster.
    func row(_ row: Int) throws -> [Float] {
        guard row >= 0, row < height else { return [] }
        var out = [Float](repeating: 0, count: width)
        let tileRow = row / tile.height
        let from = (row % tile.height) * tile.width
        for across in 0..<tilesAcross {
            let samples = try decoded(tileRow * tilesAcross + across)
            let start = across * tile.width
            let span = min(tile.width, width - start)
            guard span > 0, from + span <= samples.count else { continue }
            out.replaceSubrange(start..<(start + span), with: samples[from..<(from + span)])
        }
        return out
    }

    /// Forgets the decoded tiles; the file stays open and a tile asked again is decoded
    /// again. Called once the cell this file covers is written, so a mosaic over hundreds
    /// of cells does not hold every one of them decoded.
    func dropDecoded() {
        decodedTiles.withLock { $0.removeAll() }
    }

    private func decoded(_ index: Int) throws -> [Float] {
        if let hit = decodedTiles.withLock({ $0[index] }) { return hit }
        var raw = try stored(index)
        let floats = tile.floats(from: &raw)
        decodedTiles.withLock { $0[index] = floats }
        return floats
    }

    // MARK: Tiles as the file holds them

    /// A tile's bytes decompressed: as many as a whole tile has, zeroed past what a short
    /// last strip holds.
    private func stored(_ index: Int) throws -> [UInt8] {
        guard index >= 0, index < offsets.count else { throw Trouble.truncated }
        let offset = offsets[index], count = counts[index]
        guard offset >= 0, count >= 0, offset + count <= data.count else { throw Trouble.truncated }
        let wanted = tile.bytes
        // A strip holds 1 of 2 sizes: whole, or the rows the image has left.
        let least = leastBytes(of: index) ?? wanted
        var raw = [UInt8](unsafeUninitializedCapacity: wanted) { _, filled in filled = wanted }
        let held: Int

        switch compression {
        case TIFF.Compression.none:
            guard count >= least else { throw Trouble.truncated }
            held = count >= wanted ? wanted : least
            data.withUnsafeBytes { bytes in
                _ = raw.withUnsafeMutableBytes { out in
                    UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + held)]).copyBytes(to: out)
                }
            }
        case TIFF.Compression.lzw, TIFF.Compression.packBits:
            let body = data.subdata(in: offset..<(offset + count))
            let out =
                compression == TIFF.Compression.lzw
                ? TIFF.lzw(body, expecting: wanted)
                : TIFF.packBits(body, expecting: wanted)
            guard out.count >= least else { throw Trouble.truncated }
            held = out.count >= wanted ? wanted : least
            raw.replaceSubrange(0..<held, with: out[0..<held])
        default:
            // Adobe DEFLATE is a wrapped stream: header, body and adler32 checksum together.
            guard count > 2 else { throw Trouble.truncated }
            do {
                held = try data.withUnsafeBytes { bytes in
                    try raw.withUnsafeMutableBufferPointer { out in
                        try Deflate.inflate(
                            UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]),
                            into: out
                        )
                    }
                }
            } catch {
                throw Trouble.truncated
            }
            guard held == wanted || held == least else { throw Trouble.truncated }
        }
        if held < wanted {
            raw.withUnsafeMutableBufferPointer { ($0.baseAddress! + held).update(repeating: 0, count: wanted - held) }
        }
        return raw
    }

    /// The bytes a short last strip must hold; nil for tiles and full strips.
    private func leastBytes(of index: Int) -> Int? {
        guard stripped else { return nil }
        let rows = height - index * tile.height
        guard rows > 0, rows < tile.height else { return nil }
        return rows * tile.width * tile.bytesPerSample
    }
}
