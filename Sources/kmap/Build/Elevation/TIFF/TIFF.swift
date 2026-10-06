import Foundation

/// What the TIFF readers share: the numbers the format names things by, and how its
/// integers are read.
enum TIFF {
    enum Tag {
        static let imageWidth = 256, imageLength = 257, bitsPerSample = 258
        static let compression = 259, stripOffsets = 273, samplesPerPixel = 277
        static let rowsPerStrip = 278, stripByteCounts = 279, predictor = 317
        static let tileWidth = 322, tileLength = 323, tileOffsets = 324, tileByteCounts = 325
        static let sampleFormat = 339
        static let modelPixelScale = 33550, modelTiepoint = 33922, geoKeyDirectory = 34735
        static let gdalNodata = 42113
    }

    enum Compression {
        static let none = 1, lzw = 5, deflate = 8, packBits = 32773, adobeDeflate = 32946
    }

    enum Predictor { static let none = 1, horizontal = 2, floatingPoint = 3 }
    enum SampleFormat { static let unsigned = 1, signed = 2, float = 3 }

    /// The field types named below; the rest go by number.
    enum FieldType { static let byte = 1, short = 3, long = 4, float = 11, double = 12, long8 = 16 }

    /// The version word after the byte-order mark.
    static let classic = 42, big = 43

    /// GeoKey GTRasterType: 1 puts the tiepoint on a cell corner, 2 on the sample itself.
    enum RasterType { static let key = 1025, area = 1, point = 2 }

    /// The byte order a file opens with: II or MM. Nil for anything else.
    static func isBigEndian(_ first: UInt8, _ second: UInt8) -> Bool? {
        switch (first, second) {
        case (0x49, 0x49): false
        case (0x4D, 0x4D): true
        default: nil
        }
    }

    /// Bytes per value of a field type; 0 for a type the format does not define.
    static func size(ofType type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12, 16, 17, 18: 8
        default: 0
        }
    }

    /// The raster type a GeoKey directory states, nil where it has none. The directory
    /// is 4 numbers of header, the 4th the key count, then 4 numbers a key.
    static func rasterType(in keys: [Double]) -> Int? {
        guard keys.count >= 4, keys[3].isFinite else { return nil }
        var found: Int?
        for k in 0..<Int(min(max(keys[3], 0), 65536)) {
            let at = 4 + k * 4
            guard at + 3 < keys.count else { break }
            if Int(exactly: keys[at]) == RasterType.key, let value = Int(exactly: keys[at + 3]) { found = value }
        }
        return found
    }
}
