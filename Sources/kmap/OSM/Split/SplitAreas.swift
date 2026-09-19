import Foundation

/// Deciding the areas: the map cut into grid-aligned tiles by node count, and the two
/// corrections a cut may need afterwards.
extension TileSplitter {
    /// More areas than this is a runaway split, not a map.
    private static let mostAreas = 4096
    /// A boundary on a multiple of this is round enough to show as a seam.
    private static let tooRoundStride: Int32 = 1 << 16

    /// Moves interior tile boundaries off very round coordinates. On a boundary with more
    /// than 13 trailing zero bits both neighbours place a subdivision edge at the same
    /// coordinate at every zoom and a receiver draws the join as a line. Only boundaries
    /// shared by two areas move, as one value, so the areas still partition the ground.
    static func nudgedOffPowersOfTwo(_ areas: [Area]) -> [Area] {
        guard areas.count > 1 else { return areas }

        func tooRound(_ v: Int32) -> Bool {
            v != 0 && v % tooRoundStride == 0
        }
        func interior(_ pick: (Area) -> (Int32, Int32)) -> Set<Int32> {
            var lows: Set<Int32> = [], highs: Set<Int32> = []
            for area in areas {
                let (low, high) = pick(area)
                lows.insert(low); highs.insert(high)
            }
            return lows.intersection(highs).filter(tooRound)
        }
        let lats = interior { ($0.minLat, $0.maxLat) }
        let lons = interior { ($0.minLon, $0.maxLon) }
        guard !lats.isEmpty || !lons.isEmpty else { return areas }

        // One grid cell, so the boundary stays on the grid the whole split lives on.
        func moved(_ v: Int32, _ set: Set<Int32>) -> Int32 {
            set.contains(v) ? v + TileSplitter.grain : v
        }
        return areas.map {
            Area(
                minLat: moved($0.minLat, lats),
                minLon: moved($0.minLon, lons),
                maxLat: moved($0.maxLat, lats),
                maxLon: moved($0.maxLon, lons)
            )
        }
    }

    static func refined(_ areas: [Area], splitting failed: Set<Int>) -> [Area] {
        var out: [Area] = []
        for (index, area) in areas.enumerated() {
            guard failed.contains(index) else {
                out.append(area)
                continue
            }
            let tall = (area.maxLat - area.minLat) >= (area.maxLon - area.minLon)
            let low = tall ? area.minLat : area.minLon
            let high = tall ? area.maxLat : area.maxLon
            // The midpoint, held to the alignment grid. A cut that cannot leave both
            // halves at least one cell wide leaves the area alone.
            let cut = ((low + (high - low) / 2) >> TileSplitter.gridShift) << TileSplitter.gridShift
            guard cut > low, cut < high else {
                out.append(area)
                continue
            }
            if tall {
                out.append(
                    Area(
                        minLat: area.minLat,
                        minLon: area.minLon,
                        maxLat: cut,
                        maxLon: area.maxLon
                    )
                )
                out.append(
                    Area(
                        minLat: cut,
                        minLon: area.minLon,
                        maxLat: area.maxLat,
                        maxLon: area.maxLon
                    )
                )
            } else {
                out.append(
                    Area(
                        minLat: area.minLat,
                        minLon: area.minLon,
                        maxLat: area.maxLat,
                        maxLon: cut
                    )
                )
                out.append(
                    Area(
                        minLat: area.minLat,
                        minLon: cut,
                        maxLat: area.maxLat,
                        maxLon: area.maxLon
                    )
                )
            }
        }
        return out
    }

    /// Nodes a tile may hold. `maxNodes` keeps a tile inside Garmin's 16 MB drawing
    /// section; the node count divided by `leastTiles` competes with it, and the smaller
    /// of the two wins.
    func nodeCap(for nodes: Int) -> Int {
        guard options.leastTiles > 1 else { return options.maxNodes }
        let spread = (nodes + options.leastTiles - 1) / options.leastTiles
        return min(options.maxNodes, max(options.leastNodesPerTile, spread))
    }

    /// Counts nodes on the alignment grid and cuts the map into grid-aligned areas, none
    /// over the node cap, together covering every node. Each cut runs along the longer
    /// axis at the weighted median.
    func computeAreas() throws -> [Area] {
        var density = Density()
        // The header's bounding box is the map: areas are cut inside it and the fringe
        // beyond it is not counted. One window per input, and a node is kept if it falls
        // inside any of them.
        for input in options.inputs {
            guard let bbox = try reader(input).headerBBox() else { continue }
            density.clips.append(
                (
                    minLatCell: Self.mapUnits(bbox.minLat) >> TileSplitter.gridShift,
                    minLonCell: Self.mapUnits(bbox.minLon) >> TileSplitter.gridShift,
                    maxLatCell: (Self.mapUnits(bbox.maxLat) + TileSplitter.gridMask) >> TileSplitter.gridShift,
                    maxLonCell: (Self.mapUnits(bbox.maxLon) + TileSplitter.gridMask) >> TileSplitter.gridShift
                )
            )
            log(
                String(
                    format: "covers %.4f..%.4f / %.4f..%.4f",
                    bbox.minLat,
                    bbox.maxLat,
                    bbox.minLon,
                    bbox.maxLon
                )
            )
        }
        density.prepare()
        for input in options.inputs {
            let clips = density.clips
            for part in try reader(input).readConcurrently(make: {
                var sink = Density()
                sink.clips = clips
                sink.prepare()
                return sink
            }) {
                density.merge(part)
            }
        }
        guard density.total > 0 else { throw Trouble.empty }
        // Fringe nodes, outside every window, go uncounted, so this is a lower
        // bound on the file's node count.
        countedNodes = density.total
        density.seal()

        let cap = nodeCap(for: density.total)
        var out: [Area] = []
        // How many tiles a rectangle needs decides where it is cut: taking floor(needed/2)
        // shares at a time lands on the fewest tiles.
        var queue: [(Density.Cells, Int)] = []
        let total = density.count(density.boundsCells())
        queue.append((density.boundsCells(), max(1, (total + cap - 1) / cap)))
        while let (rect, needed) = queue.popLast() {
            let count = density.count(rect)
            if count == 0 { continue }
            // Empty ground first, before any question of size: one rectangle over two
            // far-apart regions would claim all the ground between them, which the map
            // then declares it covers. Cutting through the gap gives one area per region.
            if let (a, b) = density.splitAcrossGap(rect) {
                let countA = density.count(a)
                queue.append((a, max(1, (countA + cap - 1) / cap)))
                queue.append((b, max(1, (count - countA + cap - 1) / cap)))
                continue
            }
            if needed <= 1 || count <= cap {
                out.append(rect.area)
                continue
            }
            guard out.count + queue.count < Self.mostAreas else { throw Trouble.tooManyAreas(out.count) }
            let leftShare = needed / 2
            guard let (a, b) = density.split(rect, share: Double(leftShare) / Double(needed))
            else {
                // One grid cell holds more than the cap; it cannot be split finer.
                out.append(rect.area)
                continue
            }
            let countA = density.count(a)
            queue.append((a, max(1, (countA + cap - 1) / cap)))
            queue.append((b, max(1, (count - countA + cap - 1) / cap)))
        }
        // A stable order: south to north, then west to east.
        out.sort { ($0.minLat, $0.minLon) < ($1.minLat, $1.minLon) }
        // Not trimmed back to the cells that hold nodes: the areas partition the ground
        // exactly, and trimming would leave ground in no tile, which draws as blank.
        return out
    }
}
