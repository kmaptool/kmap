import Foundation

extension TileSplitter {
    /// One record per relation: enough to settle its tiles without holding the file.
    struct RelationRecord {
        var memberNodes: [Int64] = []
        var memberWays: [Int64] = []
        var memberRelations: [Int64] = []
        var directTiles: Set<UInt16> = []
        /// A member the extract does not hold; an incomplete relation of a carried type is
        /// written to every tile.
        var hasMissingMember = false
        /// The four types mkgmap must see complete: multipolygon and boundary for the
        /// geometry, restriction for routing, associatedStreet for house numbers. Only
        /// these have their members carried across tiles.
        var carriesMembers = false
        /// Ring fill applies to the two polygon kinds alone.
        var fillsRings = false
    }
}
