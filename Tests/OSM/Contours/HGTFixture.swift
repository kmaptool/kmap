import Foundation

/// Builds the elevation tiles the tests read.
///
/// A tile is 3601x3601 samples of big-endian `Int16`. Rows that repeat are encoded once.
enum HGTFixture {
    static let side = 3601

    /// Encodes one row of heights as big-endian bytes.
    private static func encode(_ heights: [Int16]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: heights.count * 2)
        heights.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { out in
                for index in 0..<source.count {
                    let value = UInt16(bitPattern: source[index])
                    out[index * 2] = UInt8(value >> 8)
                    out[index * 2 + 1] = UInt8(value & 0xFF)
                }
            }
        }
        return bytes
    }

    private static func write(_ rows: [[UInt8]], to url: URL) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(side * side * 2)
        for row in rows { bytes.append(contentsOf: row) }
        try Data(bytes).write(to: url)
    }

    /// A tile of one height throughout.
    @discardableResult
    static func constant(_ height: Int16, at url: URL) throws -> URL {
        let one = encode([Int16](repeating: height, count: side))
        try write([[UInt8]](repeating: one, count: side), to: url)
        return url
    }

    /// A tile whose height depends only on the row index.
    @discardableResult
    static func rowConstant(at url: URL, _ height: (Int) -> Int16) throws -> URL {
        var rows: [[UInt8]] = []
        rows.reserveCapacity(side)
        var lastHeight: Int16?
        var lastRow: [UInt8] = []
        for row in 0..<side {
            let value = height(row)
            if value != lastHeight {
                lastRow = encode([Int16](repeating: value, count: side))
                lastHeight = value
            }
            rows.append(lastRow)
        }
        try write(rows, to: url)
        return url
    }

    /// A tile given row by row. Rows that repeat are encoded once.
    @discardableResult
    static func rows(at url: URL, _ heights: (Int) -> [Int16]) throws -> URL {
        var rows: [[UInt8]] = []
        rows.reserveCapacity(side)
        var lastHeights: [Int16]?
        var lastRow: [UInt8] = []
        for row in 0..<side {
            let values = heights(row)
            if values != lastHeights {
                lastRow = encode(values)
                lastHeights = values
            }
            rows.append(lastRow)
        }
        try write(rows, to: url)
        return url
    }
}
