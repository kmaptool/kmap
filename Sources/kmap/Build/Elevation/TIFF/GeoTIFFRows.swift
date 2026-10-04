import CVector
import Foundation

extension GeoTIFF {
    // MARK: Rows of 32-bit floats

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

    /// Rows under predictor 3 to numbers, 16 bytes at a time: each row is 4 planes of
    /// bytes, most significant first, differenced as 1 run. False, having done nothing,
    /// in a build with no vector code.
    static func vectorFloatRows(
        _ start: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        into floats: UnsafeMutablePointer<Float>
    ) -> Bool {
        kmap_float_rows(start, width, rows, floats) != 0
    }

    /// The same a byte at a time: no vector code, and the tests.
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
}
