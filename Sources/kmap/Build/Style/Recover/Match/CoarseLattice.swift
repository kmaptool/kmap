import Foundation

extension CoarseEvidence {
    /// One extract's ways, indexed by a lattice of the given coarseness.
    struct Lattice {
        let shift: UInt64
        var wayCells: [[UInt64]] = []
        var byCell: [UInt64: [Int32]] = [:]
        /// Which of the ways are closed rings. A point standing on a road is not the
        /// road; a point inside a building may well be the building, which is how
        /// mkgmap plants a point for a tagged area in the first place.
        var closed: [Bool] = []

        init(
            _ index: GroundIndex,
            shift: UInt64 = CoarseEvidence.latticeShift,
            ringsOnly: Bool = false
        ) {
            self.shift = shift
            wayCells.reserveCapacity(index.ways.count)
            closed.reserveCapacity(index.ways.count)
            for (slot, way) in index.ways.enumerated() {
                var seen = Set<UInt64>()
                var cells: [UInt64] = []
                for cell in way.cells {
                    let q = quantize(cell, shift: shift)
                    if seen.insert(q).inserted { cells.append(q) }
                }
                let ring =
                    way.cells.count >= GarminGrid.ringVertices
                    && way.cells.first == way.cells.last
                closed.append(ring)
                wayCells.append(cells)
                guard !ringsOnly || ring else { continue }
                for q in cells { byCell[q, default: []].append(Int32(slot)) }
            }
            // A cell half the town passes through names nobody.
            byCell = byCell.filter { $0.value.count <= tooBusyCell }
        }
    }

    /// The tagged nodes of one extract on a zoomed-out level's lattice, for the points
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
