import Foundation

extension TileSplitter {
    struct Plan {
        /// Extra tiles for a node, beyond the one it sits in. A flat sorted table of
        /// interned pairs, read by binary search from every worker at once.
        var extra = ExtraTiles()
        /// The sets themselves, held once each. See `TileSets`.
        var sets = TileSets()
        /// Which set of tiles a way that spans tiles, or is carried by a relation, needs.
        var wayTiles: [Int64: Int32] = [:]
        /// The same for every relation worth writing.
        var relationTiles: [Int64: Int32] = [:]
    }
}
