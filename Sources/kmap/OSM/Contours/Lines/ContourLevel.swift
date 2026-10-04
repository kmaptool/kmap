import Foundation

extension Contours {
    /// Where every crossing sits and what joins to what, one set per level.
    ///
    /// Crossings are numbered, not keyed: the edge key is used once, so the second cell
    /// sharing an edge can find what the first made. Everything after that, position,
    /// links, walking segments into lines, is an array index.
    struct Level {
        /// How far along its edge each crossing sits.
        var along: [Double] = []
        /// The edge each crossing sits on, resolved to a position at the end.
        var edge: [Int32] = []
        /// What joins to what. Exactly two slots: a crossing sits on one edge, an edge is
        /// shared by at most two cells, and a cell joins each of its crossings once. -1 is
        /// an unfilled slot, that is, a loose end.
        var linkA: [Int32] = []
        var linkB: [Int32] = []
        /// One row's worth of edges, in place of a map from edge key to crossing number:
        /// one slot per column holding the number, and beside it the row that slot belongs
        /// to. Cells sharing an edge are neighbours in the sweep (an east edge is shared by
        /// the rows above and below, a south edge by the columns left and right) and the
        /// stored row makes a stale slot read as empty without clearing.
        var eastID: [Int32]
        var eastRow: [Int32]
        var southID: [Int32]
        var southRow: [Int32]

        init(width: Int) {
            eastID = [Int32](repeating: -1, count: width)
            eastRow = [Int32](repeating: -1, count: width)
            southID = [Int32](repeating: -1, count: width)
            southRow = [Int32](repeating: -1, count: width)
        }

        /// The crossing on an east edge, created if this is the first cell to reach it.
        /// Both cells sharing the edge derive `along` from the same two samples, so the
        /// first to arrive settles it.
        mutating func east(row: Int32, column: Int, key: Int32, at position: Double) -> Int32 {
            if eastRow[column] == row { return eastID[column] }
            let made = make(key, position)
            eastRow[column] = row
            eastID[column] = made
            return made
        }

        mutating func south(row: Int32, column: Int, key: Int32, at position: Double) -> Int32 {
            if southRow[column] == row { return southID[column] }
            let made = make(key, position)
            southRow[column] = row
            southID[column] = made
            return made
        }

        private mutating func make(_ key: Int32, _ position: Double) -> Int32 {
            let made = Int32(along.count)
            along.append(position)
            edge.append(key)
            linkA.append(-1)
            linkB.append(-1)
            return made
        }

        mutating func join(_ first: Int32, _ second: Int32) {
            // Both second slots must still be free: only the two cells sharing a crossing's
            // edge can join it, and each joins it once.
            assert(
                linkB[Int(first)] < 0 && linkB[Int(second)] < 0,
                "a crossing joined three ways — an edge is shared by at most two cells"
            )
            if linkA[Int(first)] < 0 { linkA[Int(first)] = second } else { linkB[Int(first)] = second }
            if linkA[Int(second)] < 0 { linkA[Int(second)] = first } else { linkB[Int(second)] = first }
        }
    }
}
