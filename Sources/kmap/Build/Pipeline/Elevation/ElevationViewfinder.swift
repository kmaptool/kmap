import Foundation

/// Viewfinder Panoramas: zip archives of ready `.hgt`, one degree at a time.

extension BuildPipeline {
    /// Fetches the Viewfinder tiles covering the region, one degree at a time.
    ///
    /// A cell is tried at each resolution the recipe names until one answers: `view1,view3`
    /// takes the finer where it exists and the coarser where it does not. A cell no
    /// resolution carries is open sea, which is not a failure.
    func fetchViewfinderTiles(_ resolutions: [Int], covering bbox: BBox, last: Bool) async throws {
        // Cells a source listed before the first view entry already converted are
        // settled; Viewfinder fills what they left. view1 against view3 is chained
        // below, per cell.
        let all = degreeCellNames(of: bbox)
        let earlier =
            resolutions.first
            .map { earlierSourceDirectories(before: ViewfinderDEM.sourceID($0)) } ?? []
        let cells = all.filter { name in
            !earlier.contains { FileTools.exists($0.appendingPathComponent("\(name).hgt")) }
        }
        // A source with nothing to do says so only in the detailed log.
        guard !cells.isEmpty else {
            log.debug("nothing left for Viewfinder — every cell is already held")
            if last { elevationDownloadsFinished() }
            return
        }
        if cells.count < all.count {
            log.append(
                "\(all.count - cells.count) cell(s) already held by an earlier"
                    + " source — Viewfinder fills the \(cells.count) left"
            )
        }
        let downloader = Downloader(log: log)
        let runner = makeRunner()
        var indexes: [Int: ViewfinderDEM.Index] = [:]
        for resolution in resolutions {
            indexes[resolution] = try await ViewfinderDEM.index(resolution) { self.log.append($0) }
        }

        var have = 0, missing: [String] = []
        // Cells an archive should have held and did not come: a failure, not sea.
        var unreached: [String] = []
        var lastTrouble: Error?
        for (position, cell) in cells.enumerated() {
            var found = false
            var failed = false
            for resolution in resolutions {
                let cached = ViewfinderDEM.cachedTile(cell, resolution: resolution)
                if ViewfinderDEM.isComplete(cached, resolution: resolution) {
                    found = true
                    break
                }
                guard var index = indexes[resolution] else { continue }
                // Kept on a throw too: a fetch that finds a claimed cell missing corrects it.
                defer { indexes[resolution] = index }
                do {
                    try Task.checkCancellation()
                    _ = try await ViewfinderDEM.fetch(
                        cell,
                        resolution: resolution,
                        index: &index,
                        downloader: downloader,
                        runner: runner
                    ) {
                        self.log.append($0)
                    }
                    found = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch  where Task.isCancelled {
                    // A stop on the last cell would otherwise read as open sea.
                    throw CancellationError()
                } catch ViewfinderDEM.Trouble.unreachable(let area, let why) {
                    failed = true
                    lastTrouble = ViewfinderDEM.Trouble.unreachable(area, why)
                    continue
                } catch {
                    continue
                }
            }
            if found {
                have += 1
            } else if failed {
                unreached.append(cell)
            } else {
                missing.append(cell)
            }
            detail(
                .elevation,
                "Viewfinder \(position + 1)/\(cells.count) · \(cell)",
                fraction: Double(position + 1) / Double(max(1, cells.count))
            )
        }
        if last { elevationDownloadsFinished() }
        log.ok(
            "Viewfinder: \(have)/\(cells.count) tile(s) in the cache"
                + (missing.isEmpty ? "" : ", \(missing.count) not published (open sea)")
        )
        if let lastTrouble, !unreached.isEmpty {
            // With none at all the build would end with no relief and say it succeeded.
            if have == 0 { throw lastTrouble }
            log.warn(
                "Viewfinder: \(unreached.count) tile(s) could not be had (\(unreached.joined(separator: ", ")))"
                    + " — their ground has no relief this time"
            )
        }
    }
}
