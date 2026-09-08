import Foundation

/// Viewfinder Panoramas: zip archives of ready `.hgt`, one degree at a time.

extension BuildPipeline {
    /// Fetches the Viewfinder tiles covering the region, one degree at a time.
    ///
    /// A cell is tried at each resolution the recipe names until one answers: `view1,view3`
    /// takes the finer where it exists and the coarser where it does not. A cell no
    /// resolution carries is open sea, which is not a failure.
    func fetchViewfinderTiles(covering bbox: BBox) async throws {
        // Cells a source listed before the first view entry already converted are
        // settled; Viewfinder fills what they left. view1 against view3 is chained
        // below, per cell.
        let all = degreeCellNames(of: bbox)
        let earlier = viewfinderResolutions.first
            .map { earlierSourceDirectories(before: ViewfinderDEM.sourceID($0)) } ?? []
        let cells = all.filter { name in
            !earlier.contains { FileTools.exists($0.appendingPathComponent("\(name).hgt")) }
        }
        if cells.count < all.count {
            log.append("\(all.count - cells.count) cell(s) already held by an earlier"
                       + " source — Viewfinder fills the \(cells.count) left")
        }
        guard !cells.isEmpty else {
            log.append("nothing left for Viewfinder — every cell is already held")
            if isLastFetching(.viewfinder) { elevationDownloadsFinished() }
            return
        }
        let downloader = Downloader(log: log)
        let runner = makeRunner()
        var indexes: [Int: ViewfinderDEM.Index] = [:]
        for resolution in viewfinderResolutions {
            indexes[resolution] = try await ViewfinderDEM.index(resolution,
                                                                downloader: downloader) {
                self.log.append($0)
            }
        }

        var have = 0, missing: [String] = []
        for (position, cell) in cells.enumerated() {
            var found = false
            for resolution in viewfinderResolutions {
                let cached = ViewfinderDEM.cachedTile(cell, resolution: resolution)
                if ViewfinderDEM.isComplete(cached, resolution: resolution) {
                    found = true
                    break
                }
                guard var index = indexes[resolution] else { continue }
                do {
                    try Task.checkCancellation()
                    _ = try await ViewfinderDEM.fetch(cell, resolution: resolution,
                                                      index: &index,
                                                      downloader: downloader, runner: runner) {
                        self.log.append($0)
                    }
                    indexes[resolution] = index
                    found = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            if found { have += 1 } else { missing.append(cell) }
            detail(.elevation, "Viewfinder \(position + 1)/\(cells.count) · \(cell)",
                   fraction: Double(position + 1) / Double(max(1, cells.count)))
        }
        if isLastFetching(.viewfinder) { elevationDownloadsFinished() }
        log.ok("Viewfinder: \(have)/\(cells.count) tile(s) in the cache"
               + (missing.isEmpty ? "" : ", \(missing.count) not published (open sea)"))
    }
}
