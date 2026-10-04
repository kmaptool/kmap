import Foundation

extension TileSplitter {
    /// Tile sets held once each and named by number, so a caller compares and stores an
    /// Int32 rather than a set of tiles.
    struct TileSets {
        /// Sorted, so a caller that wants them in order does not sort again. Number 0 is
        /// the empty set, which is what a way nothing was planned for answers with.
        private var pool: [[UInt16]] = [[]]
        private var index: [Set<UInt16>: Int32] = [:]

        mutating func intern(_ tiles: Set<UInt16>) -> Int32 {
            if tiles.isEmpty { return 0 }
            if let known = index[tiles] { return known }
            let made = Int32(pool.count)
            pool.append(tiles.sorted())
            index[tiles] = made
            return made
        }

        subscript(_ at: Int32) -> [UInt16] { pool[Int(at)] }

        /// How many distinct sets there are.
        var count: Int { pool.count }

        /// Drops the interning table, which is wanted only while the plan is built; the
        /// sets themselves are read all through the write pass.
        mutating func sealed() { index = [:] }
    }
}
