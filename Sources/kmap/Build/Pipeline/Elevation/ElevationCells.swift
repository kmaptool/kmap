import Foundation

/// The whole-degree cells a build needs, and the region outline they are
/// trimmed and clipped to.

extension BuildPipeline {
    /// The whole-degree cells the map needs: each region's own cells, never the box
    /// around them all. Internal rather than private because the compile stage stages
    /// exactly these cells for mkgmap's DEM.
    func elevationCells() -> [(lat: Int, lon: Int)] {
        if let trimmed = outlineElevationCells { return trimmed }
        return boxElevationCells()
    }

    /// Every degree cell of the regions' ring rectangles: the raw list the outline trim
    /// starts from, and the fallback when no outline can be had.
    private func boxElevationCells() -> [(lat: Int, lon: Int)] {
        ElevationFootprint.boxCells(of: recipe.regions, fallback: recipe.coverage)
    }

    /// The same cells, named `N44E034` and so on.
    func degreeCellNames(of bbox: BBox) -> [String] {
        elevationCells().map { CopernicusDEM.cellName(lat: $0.lat, lon: $0.lon) }
    }

    /// Every region's outline rings in one osmosis .poly, for pyhgtmap's --polygon.
    /// Holes are dropped, erring towards keeping ground. Nil when any region has no
    /// outline, so the caller falls back to the rectangle rather than clip it away.
    func writeElevationClipPolygon() async -> URL? {
        var sections: [[(lon: Double, lat: Double)]] = []
        for region in recipe.regions {
            guard let rings = await regionRings(region) else { return nil }
            sections.append(contentsOf: rings.filter { !$0.subtract }.map(\.points))
        }
        guard !sections.isEmpty else { return nil }
        let text = RegionOutline.polyText(name: "kmap-elevation", sections: sections)
        let url = workDirectory.appendingPathComponent("elevation-clip.poly")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log.warn("could not write the elevation clip polygon — using the box: \(error)")
            return nil
        }
    }

    /// Cuts the cells lying wholly outside every region out of the elevation list. A cell
    /// rectangle is kept when it touches a region's outline, expanded by a tenth of a
    /// degree; a region whose outline cannot be had keeps every cell of its boxes.
    func trimElevationCells() async {
        guard outlineElevationCells == nil else { return }
        let all = boxElevationCells()
        var perRegion: [(region: Region, rings: [RegionOutline.Ring]?)] = []
        for region in recipe.regions {
            let rings = await regionRings(region)
            if rings == nil {
                // No outline, no trim: this region keeps every cell of its boxes.
                log.warn("\(region.name): no outline — its elevation is not trimmed")
            }
            perRegion.append((region, rings))
        }
        guard !perRegion.isEmpty else { return }
        let kept = ElevationFootprint.trim(all, ringsPerRegion: perRegion)
        if kept.count < all.count {
            log.ok("outline trim: \(all.count) cell(s) → \(kept.count), "
                   + "\(all.count - kept.count) fully outside the region")
        }
        outlineElevationCells = kept
    }
}
