import CVector
import Foundation

/// Reads an elevation tile from a GeoTIFF without GDAL. Accepts classic TIFF, one band,
/// tiled or stripped, uncompressed, LZW, PackBits or DEFLATE, with the horizontal or
/// floating-point predictor; anything else throws `Trouble.unsupported`. Tiles are decoded on
/// first touch and cached, since a caller reads whole rows.
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

    /// The tags read, by their TIFF numbers.
    private enum Tag {
        static let imageWidth = 256, imageLength = 257, bitsPerSample = 258
        static let compression = 259, stripOffsets = 273, samplesPerPixel = 277
        static let rowsPerStrip = 278, stripByteCounts = 279, predictor = 317
        static let tileWidth = 322, tileLength = 323, tileOffsets = 324, tileByteCounts = 325
        static let sampleFormat = 339
        static let modelPixelScale = 33550, modelTiepoint = 33922, geoKeyDirectory = 34735
    }

    /// The values of the compression tag this reader decodes.
    private enum Compression {
        static let none = 1, lzw = 5, deflate = 8, packBits = 32773, adobeDeflate = 32946
    }

    private enum Predictor { static let horizontal = 2, floatingPoint = 3 }
    private enum SampleFormat { static let signed = 2, float = 3 }

    /// The version word after the byte-order mark: classic TIFF, or BigTIFF.
    private static let classicTIFF = 42, bigTIFF = 43

    /// GeoKey GTRasterType: 1 puts the tiepoint on a cell corner, 2 on the sample itself.
    private static let rasterTypeKey = 1025, rasterIsArea = 1, rasterIsPoint = 2

    /// LZW: the two reserved codes, the first code width, and the widest.
    private static let lzwClear = 256, lzwEnd = 257, lzwFirstWidth = 9, lzwWidestCode = 12

    /// PackBits: the one count byte that means nothing.
    private static let packBitsNoOp = -128

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
    private let bigEndian: Bool
    private let tileWidth: Int
    private let tileHeight: Int

    /// A tile past this many samples is refused: the largest published DEM tile is
    /// 3600 x 3600, and a header can claim anything.
    private static let mostSamplesPerTile = 64 * 1024 * 1024
    private let offsets: [Int]
    private let counts: [Int]
    private let compression: Int
    private let predictor: Int
    private let bitsPerSample: Int
    private let sampleFormat: Int
    private let tilesAcross: Int
    /// Strips: the last one may hold only the rows left.
    private let stripped: Bool

    /// Decoded tiles, by index, guarded by its own lock.
    private let cache = Cache()

    private final class Cache {
        var tiles: [Int: [Float]] = [:]
        let lock = NSLock()
    }

    /// Forgets the decoded tiles; the file stays open and a tile asked again is decoded
    /// again. Called once the cell this file covers is written, so a mosaic over hundreds
    /// of cells does not hold every one of them decoded.
    func dropDecoded() {
        cache.lock.lock()
        cache.tiles.removeAll()
        cache.lock.unlock()
    }

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 8 else { throw Trouble.notTIFF }
        switch (data[0], data[1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: throw Trouble.notTIFF
        }
        let magic = Self.u16(data, 2, bigEndian)
        if magic == Self.bigTIFF { throw Trouble.bigTIFF }
        guard magic == Self.classicTIFF else { throw Trouble.notTIFF }

        let tags = try Self.readTagDirectory(in: data, bigEndian: bigEndian)

        // A tag value is a Double; only a finite one in range becomes an Int.
        func whole(_ value: Double) -> Int? {
            value.isFinite && value >= 0 && value < 1e15 ? Int(value) : nil
        }
        func one(_ tag: Int, _ fallback: Int) -> Int {
            tags[tag]?.first.flatMap(whole) ?? fallback
        }

        width = one(Tag.imageWidth, 0)
        height = one(Tag.imageLength, 0)
        guard width > 0, height > 0 else { throw Trouble.unsupported("no image size") }
        guard one(Tag.samplesPerPixel, 1) == 1 else { throw Trouble.unsupported("more than one band") }
        bitsPerSample = one(Tag.bitsPerSample, 32)
        sampleFormat = one(Tag.sampleFormat, 1)
        compression = one(Tag.compression, 1)
        predictor = one(Tag.predictor, 1)
        guard
            compression == Compression.none || compression == Compression.lzw
                || compression == Compression.deflate || compression == Compression.adobeDeflate
                || compression == Compression.packBits
        else {
            throw Trouble.unsupported("compression \(compression)")
        }
        guard bitsPerSample == 32 || bitsPerSample == 16 else {
            throw Trouble.unsupported("\(bitsPerSample) bits per sample")
        }

        if let tw = tags[Tag.tileWidth]?.first, let th = tags[Tag.tileLength]?.first {
            tileWidth = whole(tw) ?? 0
            tileHeight = whole(th) ?? 0
            offsets = (tags[Tag.tileOffsets] ?? []).map { whole($0) ?? -1 }
            counts = (tags[Tag.tileByteCounts] ?? []).map { whole($0) ?? -1 }
            stripped = false
        } else {
            // A stripped file is a tiled one whose tiles are full width. A strip count
            // past the height (some writers put 2^32 - 1) means one strip.
            tileWidth = width
            tileHeight = min(one(Tag.rowsPerStrip, height), height)
            offsets = (tags[Tag.stripOffsets] ?? []).map { whole($0) ?? -1 }
            counts = (tags[Tag.stripByteCounts] ?? []).map { whole($0) ?? -1 }
            stripped = true
        }
        guard !offsets.isEmpty, offsets.count == counts.count else {
            throw Trouble.unsupported("no tile offsets")
        }
        // A tile may be wider or taller than the image: the format pads it, and the DEM
        // tiles north of 80 deg are 720 samples wide in tiles of 1024.
        let (samples, overflow) = tileWidth.multipliedReportingOverflow(by: tileHeight)
        guard width > 0, height > 0, tileWidth > 0, tileHeight > 0,
            !overflow, samples <= Self.mostSamplesPerTile
        else {
            throw Trouble.unsupported("tile geometry \(tileWidth) x \(tileHeight) in \(width) x \(height)")
        }
        tilesAcross = (width + tileWidth - 1) / tileWidth

        (stepLon, stepLat, originLon, originLat) = try Self.geoPlacement(from: tags)
    }

    /// The IFD: every tag the file carries, each as the numbers it holds. A tag of an
    /// unknown type, or one pointing past the end, is skipped rather than fatal.
    private static func readTagDirectory(
        in data: Data,
        bigEndian: Bool
    ) throws -> [Int: [Double]] {
        let directory = Int(Self.u32(data, 4, bigEndian))
        guard directory + 2 <= data.count else { throw Trouble.truncated }
        let entries = Int(Self.u16(data, directory, bigEndian))

        var tags: [Int: [Double]] = [:]
        for i in 0..<entries {
            let at = directory + 2 + i * 12
            guard at + 12 <= data.count else { throw Trouble.truncated }
            let tag = Int(Self.u16(data, at, bigEndian))
            let type = Int(Self.u16(data, at + 2, bigEndian))
            let count = Int(Self.u32(data, at + 4, bigEndian))
            let size = Self.typeSize(type)
            guard size > 0 else { continue }
            var value = at + 8
            if size * count > 4 {
                value = Int(Self.u32(data, at + 8, bigEndian))
            }
            guard value + size * count <= data.count else { continue }
            var out: [Double] = []
            out.reserveCapacity(min(count, 1 << 20))
            for k in 0..<count {
                let p = value + k * size
                switch type {
                case 1: out.append(Double(data[p]))
                case 3: out.append(Double(Self.u16(data, p, bigEndian)))
                case 4: out.append(Double(Self.u32(data, p, bigEndian)))
                case 11: out.append(Double(Float(bitPattern: Self.u32(data, p, bigEndian))))
                case 12: out.append(Double(bitPattern: Self.u64(data, p, bigEndian)))
                default: break
                }
            }
            tags[tag] = out
        }
        return tags
    }

    /// Where the raster sits on the ground, from its GeoTIFF keys.
    ///
    /// ModelPixelScale (33550) is (x, y, z) with y positive downwards; ModelTiepoint
    /// (33922) is six doubles whose last three are the world position of raster (i, j).
    /// Both are required rather than defaulted: a default would place the tile silently.
    private static func geoPlacement(
        from tags: [Int: [Double]]
    ) throws -> (stepLon: Double, stepLat: Double, originLon: Double, originLat: Double) {
        guard let scale = tags[Tag.modelPixelScale], scale.count >= 2,
            let tie = tags[Tag.modelTiepoint], tie.count >= 6
        else {
            throw Trouble.unsupported("no geo-referencing")
        }
        var lon = tie[3] - tie[0] * scale[0]
        var lat = tie[4] + tie[1] * scale[1]

        // Point registration is the default where the key is absent.
        var rasterType = Self.rasterIsPoint
        if let keys = tags[Tag.geoKeyDirectory], keys.count >= 4 {
            let count = keys[3].isFinite ? Int(min(max(keys[3], 0), 65536)) : 0
            for k in 0..<count {
                let at = 4 + k * 4
                guard at + 3 < keys.count else { break }
                guard keys[at].isFinite, keys[at + 3].isFinite else { continue }
                if Int(keys[at]) == Self.rasterTypeKey { rasterType = Int(keys[at + 3]) }
            }
        }
        if rasterType == Self.rasterIsArea {
            lon += scale[0] / 2
            lat -= scale[1] / 2
        }
        return (scale[0], -scale[1], lon, lat)
    }

    /// One sample, or nil outside the raster.
    func value(row: Int, column: Int) throws -> Float? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let index = (row / tileHeight) * tilesAcross + (column / tileWidth)
        let tile = try decoded(index)
        let inside = (row % tileHeight) * tileWidth + (column % tileWidth)
        guard inside < tile.count else { return nil }
        return tile[inside]
    }

    /// The samples of one raster row, left to right, or empty outside the raster.
    func row(_ row: Int) throws -> [Float] {
        guard row >= 0, row < height else { return [] }
        var out = [Float](repeating: 0, count: width)
        let tileRow = row / tileHeight
        let inside = row % tileHeight
        for across in 0..<tilesAcross {
            let tile = try decoded(tileRow * tilesAcross + across)
            let start = across * tileWidth
            let span = min(tileWidth, width - start)
            let from = inside * tileWidth
            guard span > 0, from + span <= tile.count else { continue }
            out.replaceSubrange(start..<(start + span), with: tile[from..<(from + span)])
        }
        return out
    }

    private func decoded(_ index: Int) throws -> [Float] {
        cache.lock.lock()
        if let hit = cache.tiles[index] {
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()

        guard index >= 0, index < offsets.count else { throw Trouble.truncated }
        let bytesPerSample = bitsPerSample / 8
        let wanted = tileWidth * tileHeight * bytesPerSample
        // The last strip may stop at the image's last row, padded or not.
        let least = leastBytes(of: index, bytesPerSample: bytesPerSample) ?? wanted
        // Every path below fills `held` bytes or throws; the rest is zeroed.
        var raw = [UInt8](unsafeUninitializedCapacity: wanted) { _, filled in filled = wanted }
        var held = wanted

        let offset = offsets[index], count = counts[index]
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw Trouble.truncated
        }
        if compression == Compression.none {
            guard count >= least else { throw Trouble.truncated }
            held = count >= wanted ? wanted : least
            data.withUnsafeBytes { bytes in
                _ = raw.withUnsafeMutableBytes { out in
                    UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + held)])
                        .copyBytes(to: out)
                }
            }
        } else if compression == Compression.lzw || compression == Compression.packBits {
            let body = data.subdata(in: offset..<(offset + count))
            let out =
                compression == Compression.lzw
                ? Self.lzw(body, expecting: wanted)
                : Self.packBits(body, expecting: wanted)
            guard out.count >= least else { throw Trouble.truncated }
            held = out.count >= wanted ? wanted : least
            raw.replaceSubrange(0..<held, with: out[0..<held])
        } else {
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
            // Only the 2 sizes a strip can have are accepted.
            guard held == wanted || held == least else { throw Trouble.truncated }
        }
        if held < wanted {
            raw.withUnsafeMutableBufferPointer { ($0.baseAddress! + held).update(repeating: 0, count: wanted - held) }
        }

        let floats: [Float]
        if predictor == Predictor.floatingPoint, bytesPerSample == 4, sampleFormat == SampleFormat.float {
            floats = floatsFromPlanes(&raw)
        } else if bytesPerSample == 4, sampleFormat == SampleFormat.float {
            let count = tileWidth * tileHeight
            floats = [Float](unsafeUninitializedCapacity: count) { out, filled in
                filled = count
                raw.withUnsafeMutableBufferPointer {
                    Self.wordRows(
                        $0.baseAddress!,
                        width: tileWidth,
                        rows: tileHeight,
                        bigEndian: bigEndian,
                        differenced: predictor == Predictor.horizontal,
                        into: out.baseAddress!
                    )
                }
            }
        } else {
            undoPredictor(&raw, bytesPerSample: bytesPerSample)
            floats = samples(raw, bytesPerSample: bytesPerSample)
        }

        cache.lock.lock()
        cache.tiles[index] = floats
        cache.lock.unlock()
        return floats
    }

    /// The bytes a short last strip must hold; nil for tiles and full strips.
    private func leastBytes(of index: Int, bytesPerSample: Int) -> Int? {
        guard stripped else { return nil }
        let rows = height - index * tileHeight
        guard rows > 0, rows < tileHeight else { return nil }
        return rows * tileWidth * bytesPerSample
    }

    /// Predictor 2 stores each sample as the difference from its left neighbour; predictor 3
    /// does the same to the bytes, having first grouped a row's bytes by significance.
    /// Undoing 3 takes two passes: sum along the row bytewise, then regather each sample.
    private func undoPredictor(_ raw: inout [UInt8], bytesPerSample: Int) {
        guard predictor == Predictor.horizontal || predictor == Predictor.floatingPoint else { return }
        let stride = tileWidth * bytesPerSample
        let width = tileWidth, bigEndian = self.bigEndian
        let rows = min(tileHeight, raw.count / max(1, stride))
        let floating = predictor == Predictor.floatingPoint
        // Through pointers: every byte of every tile passes here.
        raw.withUnsafeMutableBufferPointer { buffer in
            guard let start = buffer.baseAddress, stride > 0 else { return }
            let gathered = UnsafeMutablePointer<UInt8>.allocate(capacity: floating ? stride : 1)
            defer { gathered.deallocate() }
            for r in 0..<rows {
                let row = start + r * stride
                if floating {
                    // The bytes of a row were differenced as 1 run, then stored a plane
                    // at a time: every sample's first byte, then every second, and on.
                    var sum = row[0]
                    for i in 1..<stride {
                        sum &+= row[i]
                        row[i] = sum
                    }
                    for byte in 0..<bytesPerSample {
                        let plane = row + byte * width
                        for sample in 0..<width { gathered[sample * bytesPerSample + byte] = plane[sample] }
                    }
                    row.update(from: gathered, count: stride)
                } else if bytesPerSample == 1 {
                    var sum = row[0]
                    for i in 1..<stride {
                        sum &+= row[i]
                        row[i] = sum
                    }
                } else if bytesPerSample == 4 {
                    // The same over 32-bit integer samples.
                    let words = UnsafeMutableRawPointer(row)
                    var previous: UInt32 = 0
                    for k in 0..<width {
                        let word = words.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self)
                        previous &+= bigEndian ? UInt32(bigEndian: word) : UInt32(littleEndian: word)
                        words.storeBytes(
                            of: bigEndian ? previous.bigEndian : previous.littleEndian,
                            toByteOffset: k * 4,
                            as: UInt32.self
                        )
                    }
                } else {
                    // The horizontal predictor differences samples, not bytes, so a 16-bit
                    // band is reassembled before the sum and split again after.
                    var previous: UInt16 = 0
                    for k in 0..<width {
                        let at = row + k * 2
                        let raw16 =
                            bigEndian
                            ? (UInt16(at[0]) << 8) | UInt16(at[1])
                            : (UInt16(at[1]) << 8) | UInt16(at[0])
                        let value = k == 0 ? raw16 : raw16 &+ previous
                        previous = value
                        if bigEndian {
                            at[0] = UInt8(truncatingIfNeeded: value >> 8)
                            at[1] = UInt8(truncatingIfNeeded: value)
                        } else {
                            at[1] = UInt8(truncatingIfNeeded: value >> 8)
                            at[0] = UInt8(truncatingIfNeeded: value)
                        }
                    }
                }
            }
        }
    }

    /// A 32-bit float tile under predictor 3, straight to numbers: the published DEM
    /// tiles are all this kind. Each row is 4 planes of bytes, most significant first,
    /// differenced as 1 run; the sum is undone in place and a sample is then 1 byte
    /// from each plane.
    private func floatsFromPlanes(_ raw: inout [UInt8]) -> [Float] {
        let width = tileWidth
        let stride = width * 4
        let count = width * tileHeight
        let rows = min(tileHeight, raw.count / max(1, stride))
        return [Float](unsafeUninitializedCapacity: count) { out, filled in
            filled = count
            guard let floats = out.baseAddress else { return }
            // Rows the tile did not hold are 0.
            (floats + rows * width).initialize(repeating: 0, count: count - rows * width)
            raw.withUnsafeMutableBufferPointer { buffer in
                guard let start = buffer.baseAddress else { return }
                if !Self.vectorFloatRows(start, width: width, rows: rows, into: floats) {
                    Self.floatRows(start, width: width, rows: rows, into: floats)
                }
            }
        }
    }

    /// Rows of 32-bit float words to numbers, each row summed first under predictor 2
    /// (as integers, as libtiff does).
    static func wordRows(
        _ raw: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        bigEndian: Bool,
        differenced: Bool,
        into floats: UnsafeMutablePointer<Float>
    ) {
        if !bigEndian, kmap_word_rows(raw, width, rows, differenced ? 1 : 0, floats) != 0 { return }
        plainWordRows(raw, width: width, rows: rows, bigEndian: bigEndian, differenced: differenced, into: floats)
    }

    /// The same a word at a time: no vector code, big-endian files, and the tests.
    static func plainWordRows(
        _ raw: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        bigEndian: Bool,
        differenced: Bool,
        into floats: UnsafeMutablePointer<Float>
    ) {
        let words = UnsafeRawPointer(raw)
        for r in 0..<rows {
            let line = floats + r * width
            var previous: UInt32 = 0
            for k in 0..<width {
                let word = words.loadUnaligned(fromByteOffset: (r * width + k) * 4, as: UInt32.self)
                var value = bigEndian ? UInt32(bigEndian: word) : UInt32(littleEndian: word)
                if differenced {
                    value &+= previous
                    previous = value
                }
                line[k] = Float(bitPattern: value)
            }
        }
    }

    /// The rows undone 16 bytes at a time, or false, having done nothing, in a build
    /// with no vector code.
    static func vectorFloatRows(
        _ start: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        into floats: UnsafeMutablePointer<Float>
    ) -> Bool {
        kmap_float_rows(start, width, rows, floats) != 0
    }

    /// The same a byte at a time: for a build with no vector code, and for the tests
    /// to hold the other against.
    static func floatRows(
        _ start: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        into floats: UnsafeMutablePointer<Float>
    ) {
        let stride = width * 4
        guard stride > 0 else { return }
        for r in 0..<rows {
            let row = start + r * stride
            var sum = row[0]
            for i in 1..<stride {
                sum &+= row[i]
                row[i] = sum
            }
            let p0 = row, p1 = row + width, p2 = row + 2 * width, p3 = row + 3 * width
            let line = floats + r * width
            for s in 0..<width {
                let bits = UInt32(p0[s]) << 24 | UInt32(p1[s]) << 16 | UInt32(p2[s]) << 8 | UInt32(p3[s])
                line[s] = Float(bitPattern: bits)
            }
        }
    }

    /// The bytes as numbers. Predictor 3 always leaves them most-significant-byte first,
    /// whatever the file's own byte order, since its grouping is defined that way.
    private func samples(_ raw: [UInt8], bytesPerSample: Int) -> [Float] {
        let count = tileWidth * tileHeight
        var out = [Float](repeating: 0, count: count)
        let msbFirst = predictor == Predictor.floatingPoint ? true : bigEndian
        let held = min(count, raw.count / max(1, bytesPerSample))
        let isFloat = sampleFormat == SampleFormat.float, isSigned = sampleFormat == SampleFormat.signed
        raw.withUnsafeBytes { bytes in
            out.withUnsafeMutableBufferPointer { out in
                // Each branch is a plain loop over 2 pointers, which the compiler vectorises.
                if bytesPerSample == 4 {
                    for i in 0..<held {
                        let word = bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        let bits = msbFirst ? UInt32(bigEndian: word) : UInt32(littleEndian: word)
                        out[i] = isFloat ? Float(bitPattern: bits) : Float(Int32(bitPattern: bits))
                    }
                } else {
                    for i in 0..<held {
                        let word = bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                        let bits = msbFirst ? UInt16(bigEndian: word) : UInt16(littleEndian: word)
                        out[i] = isSigned ? Float(Int16(bitPattern: bits)) : Float(bits)
                    }
                }
            }
        }
        return out
    }

    /// TIFF's LZW: codes most significant bit first, nine bits wide initially, widening one
    /// code early - at 511 rather than 512.
    private static func lzw(_ input: Data, expecting wanted: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(wanted)
        var table: [[UInt8]] = (0..<Self.lzwClear).map { [UInt8($0)] } + [[], []]
        var width = Self.lzwFirstWidth
        var previous: [UInt8]? = nil
        var bit = 0
        let bits = input.count * 8

        func next() -> Int? {
            guard bit + width <= bits else { return nil }
            var code = 0
            for _ in 0..<width {
                let byte = input[input.startIndex + bit / 8]
                code = (code << 1) | Int((byte >> (7 - UInt8(bit % 8))) & 1)
                bit += 1
            }
            return code
        }

        while let code = next() {
            if code == Self.lzwClear {
                table = (0..<Self.lzwClear).map { [UInt8($0)] } + [[], []]
                width = Self.lzwFirstWidth
                previous = nil
                continue
            }
            if code == Self.lzwEnd { break }
            var entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previous {
                entry = previous + [previous[0]]
            } else {
                break
            }
            out.append(contentsOf: entry)
            if let previous {
                table.append(previous + [entry[0]])
            }
            previous = entry
            if table.count + 1 >= (1 << width), width < Self.lzwWidestCode { width += 1 }
            if out.count >= wanted { break }
        }
        return out
    }

    /// PackBits: a run of literals, or one byte repeated.
    private static func packBits(_ input: Data, expecting wanted: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(wanted)
        var at = input.startIndex
        while at < input.endIndex, out.count < wanted {
            let n = Int(Int8(bitPattern: input[at])); at += 1
            if n >= 0 {
                let take = min(n + 1, input.endIndex - at)
                out.append(contentsOf: input[at..<(at + take)])
                at += take
            } else if n != Self.packBitsNoOp {
                guard at < input.endIndex else { break }
                out.append(contentsOf: [UInt8](repeating: input[at], count: -n + 1))
                at += 1
            }
        }
        return out
    }

    // MARK: Reading numbers out of the file

    /// Bytes per value of a TIFF field type: 1 BYTE, 3 SHORT, 4 LONG, 11 FLOAT, 12 DOUBLE
    /// and their kin.
    private static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    private static func u16(_ d: Data, _ at: Int, _ big: Bool) -> UInt16 {
        guard at + 2 <= d.count else { return 0 }
        return big
            ? (UInt16(d[at]) << 8) | UInt16(d[at + 1])
            : (UInt16(d[at + 1]) << 8) | UInt16(d[at])
    }

    private static func u32(_ d: Data, _ at: Int, _ big: Bool) -> UInt32 {
        guard at + 4 <= d.count else { return 0 }
        var out: UInt32 = 0
        if big {
            for k in 0..<4 { out = (out << 8) | UInt32(d[at + k]) }
        } else {
            for k in (0..<4).reversed() { out = (out << 8) | UInt32(d[at + k]) }
        }
        return out
    }

    private static func u64(_ d: Data, _ at: Int, _ big: Bool) -> UInt64 {
        guard at + 8 <= d.count else { return 0 }
        var out: UInt64 = 0
        if big {
            for k in 0..<8 { out = (out << 8) | UInt64(d[at + k]) }
        } else {
            for k in (0..<8).reversed() { out = (out << 8) | UInt64(d[at + k]) }
        }
        return out
    }
}
