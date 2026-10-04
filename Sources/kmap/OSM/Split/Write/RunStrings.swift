import Foundation

extension TileSplitter {
    /// The strings a run has taken from its block, numbered in the order first met.
    /// `places` answers for a block's own number; the slot past the last stands for any
    /// number the block does not hold, which reads as the empty text.
    struct RunStrings {
        private var places: [Int32] = []

        mutating func open(for block: OSMBlock) {
            places.removeAll(keepingCapacity: true)
            places.append(contentsOf: repeatElement(-1, count: block.strings.count + 1))
        }

        @inline(__always)
        mutating func place(of source: Int32, in block: OSMBlock, among strings: inout [String]) -> Int32 {
            let last = places.count - 1
            let slot = source >= 0 && Int(source) < last ? Int(source) : last
            let known = places[slot]
            if known >= 0 { return known }
            let made = Int32(strings.count)
            strings.append(block.text(Int(source)))
            places[slot] = made
            return made
        }
    }
}
