import Foundation

extension ImgElements {
    /// mkgmap's BitReader: bits taken from the low end of each byte first.
    struct BitReader {
        private let bytes: [UInt8]
        private let base: Int
        /// One past the last byte the stream may read; a bit past it reads as zero and
        /// raises `overran`.
        private let end: Int
        private(set) var position = 0
        private(set) var overran = false

        init(_ bytes: [UInt8], from base: Int, length: Int = Int.max) {
            self.bytes = bytes
            self.base = max(0, base)
            self.end = min(bytes.count, length == Int.max ? bytes.count : base + length)
        }

        private mutating func byte(at index: Int) -> Int {
            guard index >= 0, index < end else { overran = true; return 0 }
            return Int(bytes[index])
        }

        mutating func get1() -> Bool {
            let byte = byte(at: base + position / 8)
            let off = position % 8
            position += 1
            return (byte >> off) & 1 == 1
        }

        mutating func get(_ n: Int) -> Int {
            var result = 0
            var got = 0
            while got < n {
                let off = position % 8
                let byte = byte(at: base + position / 8) >> off
                var take = n - got
                if take > 8 - off { take = 8 - off }
                let mask = (1 << take) - 1
                result |= (byte & mask) << got
                got += take
                position += take
            }
            return result
        }

        /// A signed delta with mkgmap's escape: the most negative value means "add the
        /// rest of the range and read another".
        mutating func sget2(_ n: Int) -> Int {
            let top = 1 << (n - 1)
            let mask = top - 1
            var base = 0
            var result = get(n)
            while result == top {
                base += mask
                result = get(n)
            }
            if result & top == 0 {
                result += base
            } else {
                result = (result | ~mask) - base
            }
            return result
        }
    }
}
