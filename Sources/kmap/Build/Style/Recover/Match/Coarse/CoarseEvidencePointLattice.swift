import Foundation

extension CoarseEvidence {
    /// The tagged nodes of an extract on a zoomed-out level's lattice, for the points
    /// a style draws only there: a village that is a label at every zoom but the
    /// closest.
    struct PointLattice {
        let shift: Int
        var byCell: [UInt64: [Int32]] = [:]

        init(_ index: GroundIndex, shift: Int) {
            self.shift = shift
            for (slot, node) in index.nodes.enumerated() {
                byCell[GarminGrid.onLattice(node.cell, shift: shift), default: []]
                    .append(Int32(slot))
            }
        }
    }
}
