import Foundation

extension RegionSuggestion {
    /// Spots a lane measures at a time. The sums are added lane by lane in spot order, so
    /// they come out the same on any number of cores.
    private static let spotsPerLane = 512

    /// Every extract of the index against the map, each on its own ground: what an
    /// extract in the cache holds is read already, and the smallest extract over the
    /// rest is the one that holds it.
    static func stances(ofExtractsIn index: RegionIndex, on drawn: DrawnGround) -> [Candidate] {
        stances(of: owners(in: index), on: drawn).filter { $0.region.pbfURL != nil }
    }

    /// The extracts in the order ground is handed out: those in the cache, each with all
    /// it holds, then the rest of the index, smallest first.
    static func owners(in index: RegionIndex) -> [Region] {
        let cached = cachedGrounds(index: index).map(\.ground)
        let held = Set(cached.map(\.id))
        return cached
            + index.regions.values
            .filter { $0.pbfURL != nil && !held.contains($0.id) }
            .map { (region: $0, area: $0.outlineArea) }
            .sorted { ($0.area, $0.region.id) < ($1.area, $1.region.id) }
            .map(\.region)
    }

    /// The share of the map's drawn data lying on any of the grounds.
    static func share(of drawn: DrawnGround, on grounds: [Region]) -> Double {
        stances(of: grounds, on: drawn).reduce(0.0) { $0 + $1.share }
    }

    /// How a region stands to the map over its whole outline.
    static func stance(of region: Region, on drawn: DrawnGround) -> Candidate {
        stances(of: [region], on: drawn)[0]
    }

    /// How each of the extracts stands to the map, in their order. A point counts for
    /// the first of them holding it, and for no other.
    static func stances(of extracts: [Region], on drawn: DrawnGround) -> [Candidate] {
        // 1 box a ring; the single box for a region whose outline never parsed.
        let grounds = extracts.map { $0.boxes.isEmpty ? [$0.bbox] : $0.boxes }
        // Only an extract under a tile holds anything of the map.
        let near = extracts.indices.filter { at in
            grounds[at].contains { box in drawn.tiles.contains { $0.intersects(box) } }
        }
        let spots = drawn.spots
        let nearExtracts = near.map { extracts[$0] }
        let nearGrounds = near.map { grounds[$0] }
        let sums = Lanes.map((spots.count + spotsPerLane - 1) / spotsPerLane) { lane -> [Double] in
            // For each near extract: the weight and the area its own ground holds, and the
            // weight its whole outline holds.
            var held = [Double](repeating: 0, count: near.count * 3)
            var over: [Int] = []
            var own: [Int] = []
            var whole: [Int] = []
            var taken: [Bool] = []
            for spot in spots[(lane * spotsPerLane)..<min(spots.count, (lane + 1) * spotsPerLane)] {
                over.removeAll(keepingCapacity: true)
                for slot in nearGrounds.indices where nearGrounds[slot].contains(where: { $0.intersects(spot.box) }) {
                    over.append(slot)
                }
                guard !over.isEmpty else { continue }
                let cells = cells(over: spot.box)
                own.removeAll(keepingCapacity: true)
                own.append(contentsOf: repeatElement(0, count: over.count))
                whole.removeAll(keepingCapacity: true)
                whole.append(contentsOf: repeatElement(0, count: over.count))
                // The cells an extract before this one took.
                taken.removeAll(keepingCapacity: true)
                taken.append(contentsOf: repeatElement(false, count: cells.count))
                var free = cells.count
                for at in over.indices {
                    let extract = nearExtracts[over[at]]
                    // An outline that does not run through the box holds all of it or none.
                    if let all = extract.holdsWhole(spot.box) {
                        guard all else { continue }
                        whole[at] = cells.count
                        own[at] = free
                        if free > 0 {
                            for cell in taken.indices { taken[cell] = true }
                            free = 0
                        }
                        continue
                    }
                    for cell in cells.indices where extract.holds(lat: cells[cell].lat, lon: cells[cell].lon) {
                        whole[at] += 1
                        if !taken[cell] {
                            taken[cell] = true
                            own[at] += 1
                            free -= 1
                        }
                    }
                }
                for at in over.indices where whole[at] > 0 {
                    let each = 1 / Double(cells.count)
                    held[over[at] * 3] += spot.weight * Double(own[at]) * each
                    held[over[at] * 3 + 1] += spot.box.squareDegrees * Double(own[at]) * each
                    held[over[at] * 3 + 2] += spot.weight * Double(whole[at]) * each
                }
            }
            return held
        }
        // The own ground under the map's tiles: coverage by a union of tiles has no closed
        // form, so it is sampled, every sample carrying its own cell's area.
        let covers = Lanes.map(near.count) { slot -> (hit: Double, sampled: Double) in
            let at = near[slot]
            var hit = 0.0
            var sampled = 0.0
            for box in grounds[at] where box.squareDegrees > 0 {
                let cells = cells(over: box, steps: ownSteps)
                let cellArea = box.squareDegrees / Double(cells.count)
                let under = drawn.tiles.filter { $0.intersects(box) }
                let before = (0..<at).filter { grounds[$0].contains { $0.intersects(box) } }
                for cell in cells where extracts[at].holds(lat: cell.lat, lon: cell.lon) {
                    if before.contains(where: { extracts[$0].holds(lat: cell.lat, lon: cell.lon) }) { continue }
                    sampled += cellArea
                    if under.contains(where: { $0.contains(lat: cell.lat, lon: cell.lon) }) { hit += cellArea }
                }
            }
            return (hit, sampled)
        }

        let total = spots.reduce(0.0) { $0 + $1.weight }
        let wholeArea = spots.reduce(0.0) { $0 + $1.box.squareDegrees }
        var out = extracts.map { Candidate(region: $0, inside: 0, share: 0, density: 0, drawn: 0, whole: 0) }
        for (slot, at) in near.enumerated() {
            let held = sums.reduce(0.0) { $0 + $1[slot * 3] }
            let heldArea = sums.reduce(0.0) { $0 + $1[slot * 3 + 1] }
            let heldWhole = sums.reduce(0.0) { $0 + $1[slot * 3 + 2] }
            let share = total > 0 ? held / total : 0
            let areaShare = wholeArea > 0 ? heldArea / wholeArea : 0
            out[at] = Candidate(
                region: extracts[at],
                inside: covers[slot].sampled > 0 ? covers[slot].hit / covers[slot].sampled : 0,
                share: share,
                density: areaShare > 0 ? share / areaShare : 0,
                drawn: held,
                whole: total > 0 ? heldWhole / total : 0
            )
        }
        return out
    }

    /// Samples a side over a region's box.
    private static let ownSteps = 24

    /// The box as a grid of cell-centre points: stepped to the box where no count is
    /// given, 6 to 24 a side, so a region smaller than the box still catches samples.
    static func cells(over box: BBox, steps: Int? = nil) -> [(lat: Double, lon: Double)] {
        let steps = steps ?? max(6, min(24, Int(max(box.maxLon - box.minLon, box.maxLat - box.minLat) * 2)))
        var out: [(lat: Double, lon: Double)] = []
        out.reserveCapacity(steps * steps)
        for row in 0..<steps {
            for column in 0..<steps {
                let f = (Double(row) + 0.5) / Double(steps)
                let g = (Double(column) + 0.5) / Double(steps)
                out.append(
                    (lat: box.minLat + f * (box.maxLat - box.minLat), lon: box.minLon + g * (box.maxLon - box.minLon))
                )
            }
        }
        return out
    }
}
