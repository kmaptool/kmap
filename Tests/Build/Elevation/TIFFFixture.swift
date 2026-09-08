import Foundation

/// A GeoTIFF built byte by byte: the smallest TIFF this reader accepts, with whatever
/// variation a case needs — either byte order, tiles or strips, either predictor, and
/// point- or area-registered samples.
struct TIFFFixture {
    var width = 4
    var height = 3
    /// Row-major, height × width.
    var samples: [Float] = []
    /// 16 for Int16, 32 for Float32.
    var bits = 16
    /// 2 signed integer, 3 floating point — as the TIFF sample format tag has it.
    var format = 2
    var tile: (width: Int, height: Int)?
    var predictor = 1
    var bigEndian = false
    /// 1 says the tiepoint is a cell corner, 2 that it is the sample itself.
    var rasterType = 2
    var origin = (lon: 33.0, lat: 45.0)
    var step = 0.25
    /// Latitude step when it differs from the longitude one, as in a thinned tile where
    /// longitude widens and latitude stays at the base step.
    var stepLat: Double?
    /// Written into the header instead of 42, for the cases that must be refused.
    var magic = 42
    /// Off to leave out the tag saying where on Earth the samples are.
    var placed = true
    var bands = 1

    /// Writes it into `directory` and returns the URL.
    static func write(_ fixture: TIFFFixture, into directory: URL,
                      as name: String = "tile.tif") throws -> URL {
        let big = fixture.bigEndian
        func u16(_ v: Int) -> [UInt8] {
            let x = UInt16(truncatingIfNeeded: v)
            return big ? [UInt8(x >> 8), UInt8(x & 0xFF)] : [UInt8(x & 0xFF), UInt8(x >> 8)]
        }
        func u32(_ v: Int) -> [UInt8] {
            let x = UInt32(truncatingIfNeeded: v)
            let bytes = [UInt8(x >> 24 & 0xFF), UInt8(x >> 16 & 0xFF),
                         UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
            return big ? bytes : bytes.reversed()
        }
        func f64(_ v: Double) -> [UInt8] {
            let x = v.bitPattern
            let bytes = (0..<8).map { UInt8(truncatingIfNeeded: x >> (56 - $0 * 8)) }
            return big ? bytes : bytes.reversed()
        }
        func sample(_ v: Float) -> [UInt8] {
            if fixture.bits == 16 {
                let x = UInt16(bitPattern: Int16(v.rounded()))
                return big ? [UInt8(x >> 8), UInt8(x & 0xFF)] : [UInt8(x & 0xFF), UInt8(x >> 8)]
            }
            return u32(Int(Int32(bitPattern: v.bitPattern)))
        }

        let bytesPerSample = fixture.bits / 8
        let tileWidth = fixture.tile?.width ?? fixture.width
        let tileHeight = fixture.tile?.height ?? fixture.height
        let across = (fixture.width + tileWidth - 1) / tileWidth
        let down = (fixture.height + tileHeight - 1) / tileHeight

        // Every tile written whole, padded where it runs off the raster, as TIFF has it.
        var blocks: [[UInt8]] = []
        for tileRow in 0..<down {
            for tileColumn in 0..<across {
                var block: [UInt8] = []
                for r in 0..<tileHeight {
                    var line: [Float] = []
                    for c in 0..<tileWidth {
                        let row = tileRow * tileHeight + r
                        let column = tileColumn * tileWidth + c
                        line.append(row < fixture.height && column < fixture.width
                                    ? fixture.samples[row * fixture.width + column] : 0)
                    }
                    var bytes = line.flatMap(sample)
                    if fixture.predictor == 2 {
                        // Each sample as the difference from its left neighbour.
                        var previous: Int32 = 0
                        bytes = []
                        for value in line {
                            let whole = Int32(value.rounded())
                            bytes += sample(Float(whole - previous))
                            previous = whole
                        }
                    } else if fixture.predictor == 3 {
                        // The bytes shuffled into columns, then differenced along the row;
                        // the shuffle is most significant byte first whatever the order.
                        let flat = line.flatMap { value -> [UInt8] in
                            let bits = fixture.bits == 32
                                ? value.bitPattern
                                : UInt32(UInt16(bitPattern: Int16(value.rounded())))
                            return (0..<bytesPerSample).map {
                                UInt8(truncatingIfNeeded: bits >> ((bytesPerSample - 1 - $0) * 8))
                            }
                        }
                        var shuffled: [UInt8] = []
                        for plane in 0..<bytesPerSample {
                            for k in 0..<tileWidth { shuffled.append(flat[k * bytesPerSample + plane]) }
                        }
                        var out = shuffled
                        for i in stride(from: out.count - 1, to: 0, by: -1) {
                            out[i] = out[i] &- out[i - 1]
                        }
                        bytes = out
                    }
                    block += bytes
                }
                blocks.append(block)
            }
        }

        var image: [UInt8] = []
        var blockOffsets: [Int] = []
        for block in blocks {
            blockOffsets.append(8 + image.count)
            image += block
        }

        // tag, type, count, inline-or-out-of-line payload
        var fields: [(tag: Int, type: Int, count: Int, payload: [UInt8])] = [
            (256, 4, 1, u32(fixture.width)),
            (257, 4, 1, u32(fixture.height)),
            (258, 3, 1, u16(fixture.bits)),
            (259, 3, 1, u16(1)),                       // no compression
            (277, 3, 1, u16(fixture.bands)),
            (317, 3, 1, u16(fixture.predictor)),
            (339, 3, 1, u16(fixture.format)),
        ]
        if fixture.tile != nil {
            fields += [(322, 4, 1, u32(tileWidth)), (323, 4, 1, u32(tileHeight)),
                       (324, 4, blockOffsets.count, blockOffsets.flatMap(u32)),
                       (325, 4, blocks.count, blocks.map(\.count).flatMap(u32))]
        } else {
            fields += [(273, 4, blockOffsets.count, blockOffsets.flatMap(u32)),
                       (278, 4, 1, u32(tileHeight)),
                       (279, 4, blocks.count, blocks.map(\.count).flatMap(u32))]
        }
        fields.append((33550, 12, 3, [fixture.step, fixture.stepLat ?? fixture.step, 0].flatMap(f64)))
        // Raster (0,0) maps to the stated corner.
        if fixture.placed {
            fields.append((33922, 12, 6, [0, 0, 0, fixture.origin.lon, fixture.origin.lat, 0]
                            .flatMap(f64)))
        }
        fields.append((34735, 3, 8, ([1, 1, 0, 1] + [1025, 0, 1, fixture.rasterType])
                        .flatMap(u16)))
        fields.sort { $0.tag < $1.tag }

        let directoryStart = 8 + image.count
        let directorySize = 2 + 12 * fields.count + 4
        var extras: [UInt8] = []
        var entries: [UInt8] = []
        for field in fields {
            entries += u16(field.tag) + u16(field.type) + u32(field.count)
            if field.payload.count <= 4 {
                entries += field.payload + [UInt8](repeating: 0, count: 4 - field.payload.count)
            } else {
                entries += u32(directoryStart + directorySize + extras.count)
                extras += field.payload
            }
        }

        var out: [UInt8] = big ? [0x4D, 0x4D] : [0x49, 0x49]
        out += u16(fixture.magic) + u32(directoryStart)
        out += image
        out += u16(fields.count) + entries + u32(0)
        out += extras

        let url = directory.appendingPathComponent(name)
        try Data(out).write(to: url)
        return url
    }
}
