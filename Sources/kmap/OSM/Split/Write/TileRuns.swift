import Foundation

extension TileSplitter {
    /// Which run of a block's objects each tile has: 1 run per tile the block touches, in
    /// the order first met. Kept between blocks.
    struct TileRuns {
        /// The tiles with a run, `count` of them; slots past that are spare.
        private(set) var tiles: [UInt16] = []
        private(set) var count = 0
        /// Per tile, its run, or -1.
        private var runOf: [Int32]

        init(tiles: Int) {
            runOf = [Int32](repeating: -1, count: tiles)
        }

        var tileCount: Int { runOf.count }

        /// The tile's run, and whether this call opened it.
        mutating func run(for tile: UInt16) -> (run: Int, opened: Bool) {
            let held = Int(runOf[Int(tile)])
            if held >= 0 { return (held, false) }
            let run = count
            runOf[Int(tile)] = Int32(run)
            if count == tiles.count { tiles.append(tile) } else { tiles[count] = tile }
            count += 1
            return (run, true)
        }

        mutating func clear() {
            for run in 0..<count { runOf[Int(tiles[run])] = -1 }
            count = 0
        }
    }
}
