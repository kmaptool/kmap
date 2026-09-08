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
    private let offsets: [Int]
    private let counts: [Int]
    private let compression: Int
    private let predictor: Int
    private let bitsPerSample: Int
    private let sampleFormat: Int
    private let tilesAcross: Int

    /// Decoded tiles, by index, guarded by its own lock.
    private let cache = Cache()

    private final class Cache {
        var tiles: [Int: [Float]] = [:]
        let lock = NSLock()
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
        if magic == 43 { throw Trouble.bigTIFF }
        guard magic == 42 else { throw Trouble.notTIFF }

        let tags = try Self.readTagDirectory(in: data, bigEndian: bigEndian)

        func one(_ tag: Int, _ fallback: Int) -> Int {
            tags[tag]?.first.map { Int($0) } ?? fallback
        }

        width = one(256, 0)
        height = one(257, 0)
        guard width > 0, height > 0 else { throw Trouble.unsupported("no image size") }
        guard one(277, 1) == 1 else { throw Trouble.unsupported("more than one band") }
        bitsPerSample = one(258, 32)
        sampleFormat = one(339, 1)
        compression = one(259, 1)
        predictor = one(317, 1)
        guard compression == 1 || compression == 5 || compression == 8
                || compression == 32946 || compression == 32773 else {
            throw Trouble.unsupported("compression \(compression)")
        }
        guard bitsPerSample == 32 || bitsPerSample == 16 else {
            throw Trouble.unsupported("\(bitsPerSample) bits per sample")
        }

        if let tw = tags[322]?.first, let th = tags[323]?.first {
            tileWidth = Int(tw)
            tileHeight = Int(th)
            offsets = (tags[324] ?? []).map { Int($0) }
            counts = (tags[325] ?? []).map { Int($0) }
        } else {
            // A stripped file is a tiled one whose tiles are full width.
            tileWidth = width
            tileHeight = one(278, height)
            offsets = (tags[273] ?? []).map { Int($0) }
            counts = (tags[279] ?? []).map { Int($0) }
        }
        guard !offsets.isEmpty, offsets.count == counts.count else {
            throw Trouble.unsupported("no tile offsets")
        }
        tilesAcross = (width + tileWidth - 1) / tileWidth

        (stepLon, stepLat, originLon, originLat) = try Self.geoPlacement(from: tags)
    }

    /// The IFD: every tag the file carries, each as the numbers it holds. A tag of an
    /// unknown type, or one pointing past the end, is skipped rather than fatal.
    private static func readTagDirectory(in data: Data, bigEndian: Bool) throws
        -> [Int: [Double]] {
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
    private static func geoPlacement(from tags: [Int: [Double]]) throws
        -> (stepLon: Double, stepLat: Double, originLon: Double, originLat: Double) {
        guard let scale = tags[33550], scale.count >= 2,
              let tie = tags[33922], tie.count >= 6 else {
            throw Trouble.unsupported("no geo-referencing")
        }
        var lon = tie[3] - tie[0] * scale[0]
        var lat = tie[4] + tie[1] * scale[1]

        // GTRasterType 1 means the tiepoint is a cell corner, so the sample is half a step
        // in; 2 means it is already the sample. 2 is the default here.
        var rasterType = 2
        if let keys = tags[34735], keys.count >= 4 {
            let count = Int(keys[3])
            for k in 0..<count {
                let at = 4 + k * 4
                guard at + 3 < keys.count else { break }
                if Int(keys[at]) == 1025 { rasterType = Int(keys[at + 3]) }
            }
        }
        if rasterType == 1 {
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
            guard from + span <= tile.count else { continue }
            for k in 0..<span { out[start + k] = tile[from + k] }
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
        var raw = [UInt8](repeating: 0, count: wanted)

        let offset = offsets[index], count = counts[index]
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw Trouble.truncated
        }
        if compression == 1 {
            guard count >= wanted else { throw Trouble.truncated }
            data.withUnsafeBytes { bytes in
                _ = raw.withUnsafeMutableBytes { out in
                    UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + wanted)])
                        .copyBytes(to: out)
                }
            }
        } else if compression == 5 || compression == 32773 {
            let body = data.subdata(in: offset..<(offset + count))
            let out = compression == 5 ? Self.lzw(body, expecting: wanted)
                                       : Self.packBits(body, expecting: wanted)
            guard out.count >= wanted else { throw Trouble.truncated }
            raw = Array(out[0..<wanted])
        } else {
            // Adobe DEFLATE is a zlib stream: header, body and adler32 checksum together.
            guard count > 2 else { throw Trouble.truncated }
            do {
                try data.withUnsafeBytes { bytes in
                    try raw.withUnsafeMutableBufferPointer { out in
                        try Zlib.inflate(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]),
                                         into: out, expecting: wanted)
                    }
                }
            } catch {
                throw Trouble.truncated
            }
        }

        undoPredictor(&raw, bytesPerSample: bytesPerSample)
        let floats = samples(raw, bytesPerSample: bytesPerSample)

        cache.lock.lock()
        cache.tiles[index] = floats
        cache.lock.unlock()
        return floats
    }

    /// Predictor 2 stores each sample as the difference from its left neighbour; predictor 3
    /// does the same to the bytes, having first grouped a row's bytes by significance.
    /// Undoing 3 takes two passes: sum along the row bytewise, then regather each sample.
    private func undoPredictor(_ raw: inout [UInt8], bytesPerSample: Int) {
        guard predictor == 2 || predictor == 3 else { return }
        let stride = tileWidth * bytesPerSample
        for r in 0..<tileHeight {
            let base = r * stride
            guard base + stride <= raw.count else { break }
            if predictor == 2 {
                // The horizontal predictor differences samples, not bytes, so a 16-bit band
                // is reassembled before the sum and split again after.
                if bytesPerSample == 1 {
                    for i in 1..<stride { raw[base + i] = raw[base + i] &+ raw[base + i - 1] }
                } else {
                    var previous: UInt16 = 0
                    for k in 0..<tileWidth {
                        let at = base + k * 2
                        let raw16 = bigEndian ? (UInt16(raw[at]) << 8) | UInt16(raw[at + 1])
                                              : (UInt16(raw[at + 1]) << 8) | UInt16(raw[at])
                        let value = k == 0 ? raw16 : raw16 &+ previous
                        previous = value
                        if bigEndian {
                            raw[at] = UInt8(truncatingIfNeeded: value >> 8)
                            raw[at + 1] = UInt8(truncatingIfNeeded: value)
                        } else {
                            raw[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
                            raw[at] = UInt8(truncatingIfNeeded: value)
                        }
                    }
                }
            } else {
                for i in 1..<stride {
                    raw[base + i] = raw[base + i] &+ raw[base + i - 1]
                }
                var gathered = [UInt8](repeating: 0, count: stride)
                for sample in 0..<tileWidth {
                    for byte in 0..<bytesPerSample {
                        gathered[sample * bytesPerSample + byte] =
                            raw[base + byte * tileWidth + sample]
                    }
                }
                for i in 0..<stride { raw[base + i] = gathered[i] }
            }
        }
    }

    /// The bytes as numbers. Predictor 3 always leaves them most-significant-byte first,
    /// whatever the file's own byte order, since its grouping is defined that way.
    private func samples(_ raw: [UInt8], bytesPerSample: Int) -> [Float] {
        let count = tileWidth * tileHeight
        var out = [Float](repeating: 0, count: count)
        let msbFirst = predictor == 3 ? true : bigEndian
        for i in 0..<count {
            let at = i * bytesPerSample
            guard at + bytesPerSample <= raw.count else { break }
            if bytesPerSample == 4 {
                var bits: UInt32 = 0
                if msbFirst {
                    for k in 0..<4 { bits = (bits << 8) | UInt32(raw[at + k]) }
                } else {
                    for k in (0..<4).reversed() { bits = (bits << 8) | UInt32(raw[at + k]) }
                }
                out[i] = sampleFormat == 3 ? Float(bitPattern: bits)
                                           : Float(Int32(bitPattern: bits))
            } else {
                var bits: UInt16 = 0
                if msbFirst {
                    bits = (UInt16(raw[at]) << 8) | UInt16(raw[at + 1])
                } else {
                    bits = (UInt16(raw[at + 1]) << 8) | UInt16(raw[at])
                }
                out[i] = sampleFormat == 2 ? Float(Int16(bitPattern: bits)) : Float(bits)
            }
        }
        return out
    }

    /// TIFF's LZW: codes most significant bit first, nine bits wide initially, widening one
    /// code early — at 511 rather than 512.
    private static func lzw(_ input: Data, expecting wanted: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(wanted)
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var width = 9
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
            if code == 256 {
                table = (0..<256).map { [UInt8($0)] } + [[], []]
                width = 9
                previous = nil
                continue
            }
            if code == 257 { break }
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
            if table.count + 1 >= (1 << width), width < 12 { width += 1 }
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
            } else if n != -128 {
                guard at < input.endIndex else { break }
                out.append(contentsOf: [UInt8](repeating: input[at], count: -n + 1))
                at += 1
            }
        }
        return out
    }

    // MARK: Reading numbers out of the file

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
        return big ? (UInt16(d[at]) << 8) | UInt16(d[at + 1])
                   : (UInt16(d[at + 1]) << 8) | UInt16(d[at])
    }

    private static func u32(_ d: Data, _ at: Int, _ big: Bool) -> UInt32 {
        guard at + 4 <= d.count else { return 0 }
        var out: UInt32 = 0
        if big { for k in 0..<4 { out = (out << 8) | UInt32(d[at + k]) } }
        else { for k in (0..<4).reversed() { out = (out << 8) | UInt32(d[at + k]) } }
        return out
    }

    private static func u64(_ d: Data, _ at: Int, _ big: Bool) -> UInt64 {
        guard at + 8 <= d.count else { return 0 }
        var out: UInt64 = 0
        if big { for k in 0..<8 { out = (out << 8) | UInt64(d[at + k]) } }
        else { for k in (0..<8).reversed() { out = (out << 8) | UInt64(d[at + k]) } }
        return out
    }
}
