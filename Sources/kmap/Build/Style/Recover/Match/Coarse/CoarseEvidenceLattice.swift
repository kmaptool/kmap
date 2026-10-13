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
            // Each way's cells over every core, 1 set of seen cells per core; the cells go
            // into the lattice in slot order, so each list keeps its order.
            let read = Lanes.map(index.ways.count, scratch: { Set<UInt64>() }) { seen, slot in
                let way = index.ways[slot]
                seen.removeAll(keepingCapacity: true)
                var cells: [UInt64] = []
                for cell in way.cells {
                    let q = quantize(cell, shift: shift)
                    if seen.insert(q).inserted { cells.append(q) }
                }
                let ring = way.cells.count >= GarminGrid.ringVertices && way.cells.first == way.cells.last
                return (cells: cells, ring: ring)
            }
            wayCells = read.map(\.cells)
            closed = read.map(\.ring)
            for (slot, way) in read.enumerated() where !ringsOnly || way.ring {
                for q in way.cells { byCell[q, default: []].append(Int32(slot)) }
            }
            // A cell half the town passes through names nobody.
            byCell = byCell.filter { $0.value.count <= tooBusyCell }
        }
    }
}
