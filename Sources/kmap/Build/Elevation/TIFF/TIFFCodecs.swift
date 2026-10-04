import Foundation

/// The 2 TIFF compressions that have no library behind them.
extension TIFF {
    /// LZW: the 2 reserved codes, the first code width, and the widest.
    private static let lzwClear = 256, lzwEnd = 257, lzwFirstWidth = 9, lzwWidestCode = 12

    /// PackBits: the 1 count byte that means nothing.
    private static let packBitsNoOp = -128

    /// TIFF's LZW: codes most significant bit first, 9 bits wide at first, widening 1
    /// code early, at 511 rather than 512. Stops at `wanted` bytes or where the codes end.
    static func lzw(_ input: Data, expecting wanted: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(wanted)
        let fresh: [[UInt8]] = (0..<lzwClear).map { [UInt8($0)] } + [[], []]
        var table = fresh
        var width = lzwFirstWidth
        var previous: [UInt8]?
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

        while let code = next(), code != lzwEnd {
            if code == lzwClear {
                table = fresh
                width = lzwFirstWidth
                previous = nil
                continue
            }
            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previous {
                entry = previous + [previous[0]]
            } else {
                break
            }
            out.append(contentsOf: entry)
            if let previous { table.append(previous + [entry[0]]) }
            previous = entry
            if table.count + 1 >= (1 << width), width < lzwWidestCode { width += 1 }
            if out.count >= wanted { break }
        }
        return out
    }

    /// PackBits: a count byte, then that many literals or 1 byte repeated.
    static func packBits(_ input: Data, expecting wanted: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(wanted)
        var at = input.startIndex
        while at < input.endIndex, out.count < wanted {
            let n = Int(Int8(bitPattern: input[at]))
            at += 1
            if n >= 0 {
                let take = min(n + 1, input.endIndex - at)
                out.append(contentsOf: input[at..<(at + take)])
                at += take
            } else if n != packBitsNoOp {
                guard at < input.endIndex else { break }
                out.append(contentsOf: [UInt8](repeating: input[at], count: -n + 1))
                at += 1
            }
        }
        return out
    }
}
