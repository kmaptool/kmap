import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// Stage 3, continued: traces contour lines from the elevation tiles and writes OSM summit
/// heights into the tiles the DEM layer reads. Both work one degree cell at a time, and
/// each cell gets its own reserved range of node and way ids.
extension BuildPipeline {
    /// Contour cells for the whole map, each clipped to its region's bounds, so regions
    /// far apart get contours over each of them and nothing in between.
    func contourCells() -> [BBox] {
        let merged = Self.oneCellPerDegree(recipe.regions.flatMap { $0.boxes.flatMap { degreeCells(of: $0) } })
        let cells = merged.isEmpty ? degreeCells(of: recipe.coverage) : merged
        // A cell the elevation stage trimmed has no .hgt and traces nothing.
        guard let kept = outlineElevationCells else { return cells }
        let names = Set(kept.map { HGTName.of(lat: $0.lat, lon: $0.lon) })
        return cells.filter {
            names.contains(HGTName.of(lat: $0.minLat, lon: $0.minLon))
        }
    }

    /// 1 cell for each degree, spanning every clipped piece of it: 2 regions' boxes
    /// overlap along their border, and pieces traced apart would draw that strip twice.
    static func oneCellPerDegree(_ pieces: [BBox]) -> [BBox] {
        var order: [String] = []
        var merged: [String: BBox] = [:]
        for piece in pieces {
            let name = HGTName.of(lat: Int(piece.minLat.rounded(.down)), lon: Int(piece.minLon.rounded(.down)))
            if let had = merged[name] {
                merged[name] = BBox(
                    minLon: min(had.minLon, piece.minLon),
                    minLat: min(had.minLat, piece.minLat),
                    maxLon: max(had.maxLon, piece.maxLon),
                    maxLat: max(had.maxLat, piece.maxLat)
                )
            } else {
                order.append(name)
                merged[name] = piece
            }
        }
        return order.compactMap { merged[$0] }
    }

    private func degreeCells(of bbox: BBox) -> [BBox] {
        let snapped = bbox.snappedOutward()
        // Roughly 2 km, so contours run past the border and meet neighbouring maps.
        let margin = 0.02
        let clip = BBox(
            minLon: bbox.minLon - margin,
            minLat: bbox.minLat - margin,
            maxLon: bbox.maxLon + margin,
            maxLat: bbox.maxLat + margin
        )

        var cells: [BBox] = []
        var lat = snapped.minLat
        while lat < snapped.maxLat {
            var lon = snapped.minLon
            while lon < snapped.maxLon {
                let cell = BBox(
                    minLon: max(lon, clip.minLon),
                    minLat: max(lat, clip.minLat),
                    maxLon: min(lon + 1, clip.maxLon),
                    maxLat: min(lat + 1, clip.maxLat)
                )
                // A cell the region only grazes can clip to nothing.
                if cell.maxLon - cell.minLon > 0.001, cell.maxLat - cell.minLat > 0.001 {
                    cells.append(cell)
                }
                lon += 1
            }
            lat += 1
        }
        return cells
    }

    /// Warns when a chosen elevation source needs a login that is missing or was refused.
    /// The build then falls back to the other sources listed.
    func warnIfCredentialsMissing() {
        let wanted = ElevationLogins.needed(for: recipe.demSources)
        guard wanted.contains(where: { !ElevationLogins.usable($0) }) else { return }

        log.warn(
            "\(recipe.demSources) needs a login: srtm goes through USGS EarthExplorer"
                + " (https://ers.cr.usgs.gov/register, not NASA Earthdata), alos through"
                + " JAXA. Set it in Settings, or the build falls back to whatever else you"
                + " listed."
        )
    }

    /// The outline of every chosen region as one mask, or nil if any outline is missing:
    /// clipping to a partial union would cut contours over real data.
    func regionMask() async -> GroundMask? {
        var regions: [[RegionOutline.Ring]] = []
        for region in recipe.regions {
            guard let some = await regionRings(region) else {
                log.warn(
                    "no outline for \(region.name) — contours will cover the whole"
                        + " rectangle, including ground outside the region"
                )
                return nil
            }
            regions.append(some)
        }
        guard let mask = GroundMask(regions: regions) else { return nil }
        log.append("contours will be cut to the region outline(s)")
        return mask
    }

    /// A region's `.poly`, from the cache or from beside its extract on Geofabrik. It is
    /// the exact polygon the extract was cut with.
    func regionRings(_ region: Region) async -> [RegionOutline.Ring]? {
        await RegionOutline.rings(for: region)
    }

    /// The lakes, reservoirs and river banks of every extract, for the contours to stop
    /// at. A scan that fails costs the cut and nothing else: the contours are still drawn.
    func standingWater(in extracts: [URL]) -> WaterBodies {
        var water = WaterBodies()
        for extract in extracts {
            do {
                water.add(contentsOf: try WaterScan.bodies(in: extract, shouldStop: stopAsked))
            } catch is CancellationError {
                break
            } catch {
                log.warn(
                    "could not read the water of \(extract.lastPathComponent)"
                        + " — contours will cross it: \(error.localizedDescription)"
                )
            }
        }
        if !water.isEmpty {
            log.append("contours will stop at \(water.rings.count) shoreline(s)")
        }
        return water
    }

    func contourCell(
        _ cell: BBox,
        index: Int,
        mask: GroundMask?,
        water: WaterBodies,
        directory: URL,
        major: Int,
        medium: Int
    ) async throws {
        // A non-overlapping id slice per cell, starting clear of the ids OSM itself uses.
        let nodeStart = ContourOutput.nodeIDBase + Int64(index) * ContourOutput.nodeIDSlice
        let wayStart = ContourOutput.wayIDBase + Int64(index) * ContourOutput.wayIDSlice
        let prefix = String(format: "contour%04d", index)

        // The clip is the cell, so ground the region only grazes is not traced.
        try Task.checkCancellation()

        let name = HGTName.of(lat: cell.minLat, lon: cell.minLon) + ".hgt"
        guard
            let tile = demSearchPaths()
                .map({ $0.appendingPathComponent(name) })
                .first(where: { FileTools.exists($0) })
        else { return }

        let cellStarted = ContourTiming.now()
        // A tile that will not read costs its cell and nothing else; a write that fails,
        // a full disk or a cell past its ids, fails the build as it would anywhere.
        let grid: Contours.Grid
        do {
            grid = try ContourTiming.measure("load") { try Contours.Grid(contentsOf: tile) }
        } catch {
            try rethrowIfCancelled(error)
            log.warn("\(prefix): \(error)")
            return
        }
        var tracer = Contours(grid: grid, step: recipe.contourInterval)
        tracer.clip = (
            minLat: cell.minLat, minLon: cell.minLon,
            maxLat: cell.maxLat, maxLon: cell.maxLon
        )
        let raw = tracer.trace()
        let traced = ContourTiming.measure("split") { Contours.split(raw) }
        // Cut where they leave the region. Lines share no nodes, and the mask answers
        // identically for a coordinate in whichever cell asks, so seams stay in step.
        let onGround = ContourTiming.measure("mask") { mask.map { $0.clip(traced) } ?? traced }
        // And where they meet water. Lines share no nodes, and a shore stands where it
        // stands whichever cell asks, so the seams stay in step here too.
        let lines = ContourTiming.measure("water") {
            WaterMask(
                cellAt: Int(cell.minLat.rounded(.down)),
                Int(cell.minLon.rounded(.down)),
                water: water
            )?.clip(onGround) ?? onGround
        }
        guard !lines.isEmpty else { return }
        let output = directory.appendingPathComponent("\(prefix).osm.pbf")
        let counts = try ContourTiming.measure("write") {
            try ContourOutput.write(
                lines,
                to: output,
                nodeStart: nodeStart,
                wayStart: wayStart,
                major: major,
                medium: medium
            )
        }
        ContourTiming.cell(
            index: index,
            name: tile.lastPathComponent,
            start: cellStarted,
            seconds: ContourTiming.now() - cellStarted,
            points: counts.nodes
        )
        log.append(
            "\(prefix): \(counts.ways) contour(s), \(counts.nodes) node(s)"
                + " from \(tile.lastPathComponent)"
        )
    }

    /// Cache directories (lowercased) of sources this map may not use: those whose credit
    /// lines it does not carry. FABDEM's include Copernicus's. ALOS asks for credit too,
    /// and the map names it only when it is chosen.
    static func uncreditedDirectories(chosen: [String]) -> Set<String> {
        let carried = Set(DEMSources.all.filter { chosen.contains($0.sourceID) }.flatMap(\.credits))
        let alos = ["alos1", "alos3"].filter { !chosen.contains($0) }
        return Set(
            DEMSources.all.filter { !Set($0.credits).isSubset(of: carried) }
                .map { $0.directoryName.lowercased() }
        ).union(alos)
    }

    /// The map's own cells some usable directory of the cache holds. The cache is shared,
    /// and a tile of another map's ground does not make this one's relief.
    func mapHGTCount() -> Int {
        let sources = Self.rankedDEMDirectories(chosen: demSourceList, burned: burnedElevationDirectories)
        return elevationCells().filter { cell in
            let name = HGTName.of(lat: cell.lat, lon: cell.lon) + ".hgt"
            return sources.contains { FileTools.exists($0.appendingPathComponent(name)) }
        }.count
    }

    /// Directories under the .hgt cache holding elevation files, finest first. mkgmap
    /// searches `--dem` paths in order and takes the first tile it finds.
    func demSearchPaths() -> [URL] {
        if let kept = state.withLock({ $0.demPaths }) { return kept }
        let ranked = walkDEMSearchPaths()
        state.withLock { $0.demPaths = ranked }
        return ranked
    }

    /// Forgets the ranked directories: called where tiles land or are burned, so the
    /// next ask walks the cache again. A walk per contour cell was the cost before.
    func forgetDEMSearchPaths() {
        state.withLock { $0.demPaths = nil }
    }

    private func walkDEMSearchPaths() -> [URL] {
        Self.rankedDEMDirectories(chosen: demSourceList, burned: burnedElevationDirectories)
    }

    /// The cache's elevation directories as a map naming `chosen` reads them, finest
    /// first, each of `burned` ahead of its original. The road repair reads the same.
    static func rankedDEMDirectories(chosen: [String], burned burnedDirectories: [URL] = []) -> [URL] {
        // Not inside a fetch's unpacking, whose tiles may be cut short.
        let directories = Set(
            FileTools.filesThroughLinks(under: Paths.hgtCache, extension: "hgt").map { $0.deletingLastPathComponent() }
                .filter { !$0.pathComponents.contains(where: ViewfinderDEM.isStaging) }
        )
        // The cache is shared between builds and holds sources this one did not ask for,
        // so the chosen sources rank first or the DEM disagrees with the contours.
        let uncredited = uncreditedDirectories(chosen: chosen)
        func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            // The direct sources' directory names (COP1, FAB1) differ from their ids, so the
            // generic name match below cannot connect them.
            for source in DEMSources.all
            where name == source.directoryName.lowercased() {
                if let index = chosen.firstIndex(of: source.sourceID) { return index }
            }
            if let index = chosen.firstIndex(of: name) { return index }
            // Sources not asked for still fill holes, matching resolution first, so a
            // 3-arc-second choice is not undone one cell at a time.
            let wantsOneArc = chosen.first.map { $0.contains("1") } ?? true
            return name.contains("1") == wantsOneArc ? 100 : 200
        }
        let cached = directories.filter { !uncredited.contains($0.lastPathComponent.lowercased()) }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                return ra == rb ? a.path < b.path : ra < rb
            }
        // Each burned directory is paired directly ahead of the cache it came from, so it
        // shadows only its own tiles and never outranks a finer source.
        return cached.flatMap { dir -> [URL] in
            let burned = burnedDirectories.first {
                $0.lastPathComponent == dir.lastPathComponent
            }
            return [burned, dir].compactMap { $0 }
        }
    }

    /// Writes OSM summit heights into a private copy of the tiles the DEM layer takes, from
    /// the source it takes each from. The cache is shared, and contours read it untouched:
    /// a raised summit would trace as rings.
    func burnPeakElevations(extracts: [URL]) async {
        guard recipe.demLayer, recipe.fixSummits else { return }
        let sources = demSearchPaths()
        // The tiles the DEM stage will take, by the source it takes each from.
        var wanted: [URL: Set<String>] = [:]
        for cell in elevationCells() {
            let name = HGTName.of(lat: cell.lat, lon: cell.lon)
            guard
                let source = sources.first(where: {
                    FileTools.exists($0.appendingPathComponent(name + ".hgt"))
                })
            else { continue }
            wanted[source, default: []].insert(name)
        }
        guard !wanted.isEmpty else { return }
        let root = workDirectory.appendingPathComponent("hgt-peaks", isDirectory: true)
        // A copy from an earlier attempt must not shadow the cache.
        FileTools.removeIfPresent(root)
        var burned: [URL] = []
        let peaks: [BurnPeaks.Peak]
        do {
            peaks = try BurnPeaks.peaks(in: extracts, shouldStop: stopAsked)
        } catch {
            // Cancelled rather than unreadable: nothing to say about it.
            guard !isCancelled, !Task.isCancelled else { return }
            log.warn("summit heights left out: \(error)")
            return
        }
        for (source, names) in wanted.sorted(by: { $0.key.path < $1.key.path }) {
            let destination = root.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: true
            )
            do {
                var burn = BurnPeaks(extracts: extracts, hgt: source, out: destination)
                burn.tiles = names
                burn.shouldStop = stopAsked
                let report = try burn.run(peaks: peaks)
                log.append(
                    "\(report.raised) summit height(s) written into"
                        + " \(report.written.count) tile(s) of \(source.lastPathComponent),"
                        + " \(report.rejected.count) rejected as bad OSM"
                )
                if !report.written.isEmpty { burned.append(destination) }
            } catch {
                guard !isCancelled, !Task.isCancelled else { return }
                log.warn("summit heights left out of \(source.lastPathComponent): \(error)")
            }
        }
        burnedElevationDirectories = burned
        forgetDEMSearchPaths()
    }

    /// Whether most of the map's cells are taken from 1-arc-second data, as mkgmap reads
    /// them: the first ranked directory holding each cell. The finest directory in the
    /// cache may hold none of them.
    var hasOneArcSecondData: Bool {
        let sources = demSearchPaths()
        var fine = 0, coarse = 0
        for cell in elevationCells() {
            let name = HGTName.of(lat: cell.lat, lon: cell.lon) + ".hgt"
            guard let source = sources.first(where: { FileTools.exists($0.appendingPathComponent(name)) })
            else { continue }
            if Self.isOneArcSecond(source) { fine += 1 } else { coarse += 1 }
        }
        return fine > 0 && fine >= coarse
    }

    static func isOneArcSecond(_ directory: URL) -> Bool {
        let name = directory.lastPathComponent.lowercased()
        return ["view1", "srtm1", "alos1"].contains(name)
            || DEMSources.all.contains { $0.nodes == 3601 && name == $0.directoryName.lowercased() }
    }
}
