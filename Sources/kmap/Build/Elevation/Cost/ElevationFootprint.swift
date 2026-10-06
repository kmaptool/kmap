import Foundation

/// The degree cells a set of regions actually needs. Both the build and the cost
/// estimate come through here, so the figure quoted on the build screen and the fetch
/// the build performs always agree: each region's own boxes, trimmed to the region
/// outlines where they can be had.
enum ElevationFootprint {
    /// How far past a cell's rectangle an outline may pass and still keep the cell.
    static let margin = 0.1

    /// Every degree cell of a box, by its south-west corner.
    static func cellOrigins(of bbox: BBox) -> [(lat: Int, lon: Int)] {
        let snapped = bbox.snappedOutward()
        var cells: [(lat: Int, lon: Int)] = []
        var lat = Int(snapped.minLat.rounded(.down))
        while Double(lat) < snapped.maxLat {
            var lon = Int(snapped.minLon.rounded(.down))
            while Double(lon) < snapped.maxLon {
                cells.append((lat, lon))
                lon += 1
            }
            lat += 1
        }
        return cells
    }

    /// Every degree cell of the regions' own rectangles, deduplicated, in a settled
    /// order: the raw list the outline trim starts from. The union of the regions' own
    /// boxes, never the single box around them all.
    static func boxCells(of regions: [Region], fallback: BBox = .empty) -> [(lat: Int, lon: Int)] {
        var seen = Set<String>()
        var out: [(lat: Int, lon: Int)] = []
        for region in regions {
            for cell in region.boxes.flatMap({ cellOrigins(of: $0) }) {
                let key = HGTName.of(lat: cell.lat, lon: cell.lon)
                if seen.insert(key).inserted { out.append(cell) }
            }
        }
        if out.isEmpty, fallback.isValid { return cellOrigins(of: fallback) }
        return out
    }

    /// Cuts the cells lying wholly outside every outline. A region without rings keeps the
    /// cells of its boxes and, as the margin reaches them, their neighbours: better fetched
    /// than clipped. Kept by lookup, not 1 square ring per cell: rings tested against every
    /// cell took minutes for a country without its outline.
    static func trim(
        _ all: [(lat: Int, lon: Int)],
        ringsPerRegion: [(region: Region, rings: [RegionOutline.Ring]?)],
        shouldStop: () -> Bool = { false }
    ) -> [(lat: Int, lon: Int)] {
        var rings: [RegionOutline.Ring] = []
        var boxed = Set<String>()
        for (region, some) in ringsPerRegion {
            if let some {
                rings.append(contentsOf: some.filter { !$0.subtract })
            } else {
                boxed.formUnion(
                    region.boxes.flatMap { cellOrigins(of: $0) }.map { HGTName.of(lat: $0.lat, lon: $0.lon) }
                )
            }
        }
        guard !rings.isEmpty || !boxed.isEmpty else { return all }
        // The boxes' own cells among those listed, by position.
        let kept = Set(
            all.filter { boxed.contains(HGTName.of(lat: $0.lat, lon: $0.lon)) }.map { $0.lat * 1000 + $0.lon }
        )
        var out: [(lat: Int, lon: Int)] = []
        for (at, cell) in all.enumerated() {
            if at % 256 == 0, shouldStop() { return out }
            let near = (-1...1).contains { dy in
                (-1...1).contains { dx in kept.contains((cell.lat + dy) * 1000 + cell.lon + dx) }
            }
            if near
                || (!rings.isEmpty
                    && RegionOutline.rectTouches(
                        rings,
                        minLon: Double(cell.lon) - margin,
                        minLat: Double(cell.lat) - margin,
                        maxLon: Double(cell.lon) + 1 + margin,
                        maxLat: Double(cell.lat) + 1 + margin
                    ))
            {
                out.append(cell)
            }
        }
        return out
    }

    /// The trimmed footprint in 1 call, fetching each region's outline itself: what the
    /// cost estimate uses. The build assembles the same pieces in `trimElevationCells`,
    /// where the missing outlines are also logged.
    static func cells(of regions: [Region], fallback: BBox = .empty) async -> [(lat: Int, lon: Int)] {
        let all = boxCells(of: regions, fallback: fallback)
        var perRegion: [(region: Region, rings: [RegionOutline.Ring]?)] = []
        for region in regions {
            perRegion.append((region, await RegionOutline.rings(for: region)))
        }
        return trim(all, ringsPerRegion: perRegion, shouldStop: { Task.isCancelled })
    }
}
