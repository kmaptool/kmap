import Foundation

extension TileSplitter {
    /// The strings a run has taken from its block, numbered in the order first met. Asked
    /// by the block's own number; every number the block does not hold stands for 1 entry,
    /// which reads as the empty text.
    ///
    /// A small table of its own, sized by what the run takes, rather than a slot for
    /// every string of the block: a block touches many tiles, and each would otherwise
    /// clear and keep a table as long as the block's.
    struct RunStrings {
        /// Open addressing: the block's number moved up by 2, so that 0 is a free slot and
        /// 1 is every number outside the block. A power of 2 long.
        private var keys = [Int32](repeating: 0, count: 16)
        private var values = [Int32](repeating: 0, count: 16)
        /// The slots in use, cleared when the next block opens.
        private var used: [Int] = []
        private var shift = 32 - 4
        private var blockSize = 0

        mutating func open(for block: OSMBlock) {
            if keys.count > 1024, used.count * 8 < keys.count {
                // Grown for 1 large run, and now mostly empty: back to the size most need.
                self = RunStrings()
            } else {
                for slot in used { keys[slot] = 0 }
                used.removeAll(keepingCapacity: true)
            }
            blockSize = block.strings.count
        }

        @inline(__always)
        mutating func place(of source: Int32, in block: OSMBlock, among strings: inout [String]) -> Int32 {
            let key: Int32 = source >= 0 && Int(source) < blockSize ? source + 2 : 1
            var slot = Self.slot(of: key, shift: shift)
            let mask = keys.count - 1
            while keys[slot] != 0 {
                if keys[slot] == key { return values[slot] }
                slot = (slot + 1) & mask
            }
            let made = Int32(strings.count)
            strings.append(block.text(Int(source)))
            keys[slot] = key
            values[slot] = made
            used.append(slot)
            if used.count * 2 > keys.count { grow() }
            return made
        }

        /// Fibonacci hashing: the top bits of the product, which every bit of the key moves.
        @inline(__always)
        private static func slot(of key: Int32, shift: Int) -> Int {
            Int((UInt32(bitPattern: key) &* 2_654_435_769) &>> UInt32(shift))
        }

        private mutating func grow() {
            let entries = used.map { (keys[$0], values[$0]) }
            keys = [Int32](repeating: 0, count: keys.count * 2)
            values = [Int32](repeating: 0, count: values.count * 2)
            shift -= 1
            used.removeAll(keepingCapacity: true)
            let mask = keys.count - 1
            for (key, value) in entries {
                var slot = Self.slot(of: key, shift: shift)
                while keys[slot] != 0 { slot = (slot + 1) & mask }
                keys[slot] = key
                values[slot] = value
                used.append(slot)
            }
        }
    }
}
