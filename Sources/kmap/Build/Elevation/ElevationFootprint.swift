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
                let key = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
                if seen.insert(key).inserted { out.append(cell) }
            }
        }
        if out.isEmpty, fallback.isValid { return cellOrigins(of: fallback) }
        return out
    }

    /// Cuts the cells lying wholly outside every outline out of the list. A region whose
    /// rings are nil keeps every cell of its own boxes, as one square ring per cell,
    /// erring towards fetching ground rather than clipping it away.
    static func trim(_ all: [(lat: Int, lon: Int)],
                     ringsPerRegion: [(region: Region, rings: [RegionOutline.Ring]?)])
        -> [(lat: Int, lon: Int)] {
        var rings: [RegionOutline.Ring] = []
        for (region, some) in ringsPerRegion {
            if let some {
                rings.append(contentsOf: some.filter { !$0.subtract })
            } else {
                let keep = Set(region.boxes.flatMap { cellOrigins(of: $0) }
                    .map { CopernicusDEM.cellName(lat: $0.lat, lon: $0.lon) })
                rings.append(contentsOf: squareRings(covering: keep, from: all))
            }
        }
        guard !rings.isEmpty else { return all }
        return all.filter { cell in
            RegionOutline.rectTouches(rings,
                                      minLon: Double(cell.lon) - margin,
                                      minLat: Double(cell.lat) - margin,
                                      maxLon: Double(cell.lon) + 1 + margin,
                                      maxLat: Double(cell.lat) + 1 + margin)
        }
    }

    /// The trimmed footprint in one call, fetching each region's outline itself: what the
    /// cost estimate uses. The build assembles the same pieces in `trimElevationCells`,
    /// where the missing outlines are also logged.
    static func cells(of regions: [Region], fallback: BBox = .empty) async -> [(lat: Int, lon: Int)] {
        let all = boxCells(of: regions, fallback: fallback)
        var perRegion: [(region: Region, rings: [RegionOutline.Ring]?)] = []
        for region in regions {
            perRegion.append((region, await RegionOutline.rings(for: region)))
        }
        return trim(all, ringsPerRegion: perRegion)
    }

    /// One square ring per named cell: how a region without an outline keeps its ground
    /// through the trim.
    private static func squareRings(covering names: Set<String>,
                                    from all: [(lat: Int, lon: Int)]) -> [RegionOutline.Ring] {
        all.filter { names.contains(CopernicusDEM.cellName(lat: $0.lat, lon: $0.lon)) }
            .map { cell in
                let lon = Double(cell.lon), lat = Double(cell.lat)
                return RegionOutline.Ring(subtract: false, points: [
                    (lon, lat), (lon + 1, lat), (lon + 1, lat + 1), (lon, lat + 1), (lon, lat)
                ])
            }
    }
}
