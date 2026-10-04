import Foundation

extension TileSplitter.AreaLookup {
    /// Up to nine areas, held without an array. A point well inside one area belongs to
    /// it alone; only a point within a grid cell of a border names more, and the
    /// neighbourhood that decides it is three cells by three.
    struct Hits: Hashable {
        /// The 3x3 cell neighbourhood cannot name more areas than it has cells.
        static let capacity = 9

        private(set) var count = 0
        private var values = SIMD16<UInt16>(repeating: TileSplitter.AreaLookup.none)

        var first: UInt16 { values[0] }

        // Slots past `count` always hold `none`, so the slots in use decide equality,
        // and hashing the words that hold them is enough.
        static func == (a: Hits, b: Hits) -> Bool { a.values == b.values }

        /// Slots in each 64-bit word hashed.
        private static let perWord = 4

        func hash(into hasher: inout Hasher) {
            let words = unsafeBitCast(values, to: SIMD4<UInt64>.self)
            hasher.combine(words[0])
            for i in stride(from: 1, to: (count + Self.perWord - 1) / Self.perWord, by: 1) {
                hasher.combine(words[i])
            }
        }

        subscript(index: Int) -> UInt16 { values[index] }

        func contains(_ area: UInt16) -> Bool {
            for i in 0..<count where values[i] == area { return true }
            return false
        }

        mutating func add(_ area: UInt16) {
            for i in 0..<count where values[i] == area { return }
            guard count < Self.capacity else { return }
            values[count] = area
            count += 1
        }

        /// Sorted, for the rare point that belongs to several: the set is interned by
        /// its contents, so two spellings of the same set must not become two entries.
        var sorted: [UInt16] {
            var out: [UInt16] = []
            out.reserveCapacity(count)
            for i in 0..<count { out.append(values[i]) }
            return out.sorted()
        }

        /// The same order, still on the stack: nine slots at most, so an insertion sort.
        var inOrder: Hits {
            var out = self
            for i in 1..<max(count, 1) {
                let value = out.values[i]
                var at = i
                while at > 0, out.values[at - 1] > value {
                    out.values[at] = out.values[at - 1]
                    at -= 1
                }
                out.values[at] = value
            }
            return out
        }
    }
}
