import Foundation

/// Copernicus GLO-30/GLO-90: GeoTIFF from the open bucket, downloaded in lanes
/// and resampled onto the arc-second grid.

extension BuildPipeline {
    /// Downloads the Copernicus tiles covering the region and converts each to `.hgt`.
    ///
    /// A missing tile is not an error: the bucket simply has nothing over open sea, and a
    /// coastal region routinely asks for degrees that are entirely water.
    func fetchCopernicusTiles(_ flavor: CopernicusDEM.Flavor, covering bbox: BBox,
                              last: Bool) async throws {
        Paths.ensure(flavor.cacheDirectory)

        // A cell a finer source listed before this one already converted is settled: the
        // DEM and the contours would take that copy anyway. What remains here is this
        // source's own share — the gaps.
        let all = elevationCells()
        let earlier = earlierSourceDirectories(before: flavor.sourceID)
        let wanted = all.filter { !cellSettledEarlier(earlier, lat: $0.lat, lon: $0.lon) }
        if wanted.count < all.count {
            log.append("\(all.count - wanted.count) cell(s) already held by an earlier"
                       + " source — this one fills the \(wanted.count) left")
        }
        guard !wanted.isEmpty else {
            log.append("nothing left for \(flavor.sourceID) — every cell is already held")
            return
        }

        // Three cell states: a finished .hgt needs nothing, a cached .tif skips straight
        // to conversion, and only the rest go over the network.
        let unconverted = wanted.filter { !FileTools.exists(flavor.cachedTile(lat: $0.lat, lon: $0.lon)) }
        guard !unconverted.isEmpty else {
            log.append("all \(wanted.count) Copernicus tile(s) already converted")
            return
        }
        let scratch = flavor.tifCacheDirectory
        Paths.ensure(scratch)
        let missing = unconverted.filter {
            !FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        if missing.count < unconverted.count {
            log.append("\(unconverted.count - missing.count) Copernicus tile(s) already downloaded — kept from an interrupted run")
        }
        log.step("fetching \(missing.count) Copernicus \(flavor.sourceID == CopernicusDEM.glo90.sourceID ? "GLO-90" : "GLO-30") tile(s)")

        // Two phases: downloads run several at a time, then conversion warps from a mosaic
        // of all the tiles. A `.hgt` grid is half a cell wider than the source square on
        // every side, so its outer nodes need the neighbour's data to sample.
        let absent = try await downloadCopernicusTifs(missing, flavor: flavor, into: scratch)

        let downloaded = unconverted.filter {
            FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        guard !downloaded.isEmpty else {
            log.ok("no Copernicus tiles here — \(absent) cell(s) are open sea")
            guard hgtFileCount() > 0 else { throw BuildError.noElevationTiles }
            return
        }

        // One mosaic over every tile just downloaded, so a node on a tile's rim samples
        // its neighbour rather than leaving a column of zeros down the join.
        let mosaic = HGTConversion.Mosaic { lat, lon in
            let file = flavor.downloadedTif(lat: lat, lon: lon)
            return FileTools.exists(file) ? file : nil
        }

        // Downloading is over for this source; the download half closes only when nothing
        // else is going to fetch. The two halves overlap across sources.
        if last, isLastFetching(.copernicus) { elevationDownloadsFinished() }
        elevationBuildStarted("converting")
        let converted = try await convertCopernicusTiles(downloaded, from: mosaic,
                                                         flavor: flavor)

        // The mosaic samples across the joins, so no .tif is deleted until the whole pass
        // is over, and a cell whose conversion failed keeps its download.
        for cell in downloaded
        where FileTools.exists(flavor.cachedTile(lat: cell.lat, lon: cell.lon)) {
            FileTools.removeIfPresent(flavor.downloadedTif(lat: cell.lat, lon: cell.lon))
        }

        log.ok("\(converted) Copernicus tile(s) converted"
               + (absent > 0 ? ", \(absent) not in the bucket (open sea)" : ""))
        guard converted > 0 || hgtFileCount() > 0 else {
            throw BuildError.noElevationTiles
        }
    }

    /// Downloads the missing Copernicus tiles, several at a time, with a live progress
    /// line. A tile the bucket does not hold is open sea, not a failure.
    ///
    /// - Returns: how many cells came back absent.
    private func downloadCopernicusTifs(_ missing: [(lat: Int, lon: Int)],
                                        flavor: CopernicusDEM.Flavor,
                                        into scratch: URL) async throws -> Int {
        let lanes = max(2, min(6, Machine.workers))
        let absent = Counter()
        let fetched = Counter()
        // Several tiles are in flight at once, so no single downloader knows the total
        // rate; this adds them up.
        let flight = Flight()
        let started = Date()

        // How fast tiles have been finishing lately rather than on average since the
        // start: a burst of early arrivals skews an average badly. See `Pace`.
        var pace = Pace()
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let done = fetched.value + absent.value
                pace.note(done: done)
                let text = Self.fetchLine(done: done, of: missing.count,
                                          received: flight.received,
                                          elapsed: Date().timeIntervalSince(started),
                                          secondsLeft: pace.secondsLeft(missing.count - done))
                self.detail(.elevation, text,
                            fraction: Double(done) / Double(max(1, missing.count)))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { monitor.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0

            func launch(_ index: Int) {
                let cell = missing[index]
                group.addTask { [weak self] in
                    guard let self else { return }
                    let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
                    guard let url = flavor.tileURL(lat: cell.lat, lon: cell.lon) else {
                        return
                    }
                    // Assembled under a working name and moved into the cache in one
                    // step, so existence in the cache is the integrity mark.
                    let tif = scratch.appendingPathComponent("\(name).tif")
                    let assembling = scratch.appendingPathComponent("\(name).assembling")
                    let downloader = Downloader(log: self.log)
                    flight.joined(downloader)
                    do {
                        // Two connections per tile: with several tiles in flight the link
                        // is already busy, and the bucket favours plain GETs.
                        try await downloader.download(url: url, to: assembling, connections: 2)
                        FileTools.removeIfPresent(tif)
                        try FileManager.default.moveItem(at: assembling, to: tif)
                        flight.left(downloader, carrying: FileTools.size(of: tif))
                        fetched.increment()
                    } catch let error where CopernicusDEM.isAbsent(error) {
                        // Nothing in the bucket means open sea, which is not a failure.
                        flight.left(downloader, carrying: 0)
                        absent.increment()
                        return
                    } catch {
                        flight.left(downloader, carrying: 0)
                        throw error
                    }
                }
                running += 1
                next += 1
            }

            while next < missing.count && running < lanes { launch(next) }
            while running > 0 {
                try await group.next()
                running -= 1
                if next < missing.count { launch(next) }
            }
        }
        monitor.cancel()
        return absent.value
    }

    /// Converts the downloaded tiles onto the arc-second grid, on every core. Cells
    /// convert independently: the mosaic and each GeoTIFF's tile cache sit behind locks,
    /// and every cell writes its own file, so order changes nothing.
    ///
    /// - Returns: how many tiles converted; a failed cell warns and keeps its download.
    private func convertCopernicusTiles(_ downloaded: [(lat: Int, lon: Int)],
                                        from mosaic: HGTConversion.Mosaic,
                                        flavor: CopernicusDEM.Flavor) async throws -> Int {
        let converted = Counter()
        let done = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let cell = downloaded[index]
                group.addTask { [weak self] in
                    guard let self else { return }
                    let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
                    do {
                        try self.convertCopernicusTile(cell, from: mosaic, flavor: flavor)
                        converted.increment()
                    } catch {
                        self.log.warn("\(name): could not be converted — \(error)")
                    }
                    done.increment()
                    self.detail(.elevationBuild,
                                "converting \(done.value)/\(downloaded.count)",
                                fraction: Double(done.value) / Double(max(1, downloaded.count)) * 0.2)
                }
                next += 1
                running += 1
            }
            while next < downloaded.count && running < max(1, Machine.workers) { launch(next) }
            while running > 0 {
                try await group.next()
                running -= 1
                // Cancellation lands between cells; the tifs are cached, so whatever is
                // skipped is picked up by the next run.
                try Task.checkCancellation()
                if next < downloaded.count { launch(next) }
            }
        }
        return converted.value
    }

    /// Resamples one degree cell of GeoTIFF onto the arc-second nodes and writes it as
    /// `.hgt`. Sampling each tile directly, rather than through an averaged VRT mosaic,
    /// avoids a second resampling where neighbouring tiles differ in sample spacing.
    private func convertCopernicusTile(_ cell: (lat: Int, lon: Int),
                                       from mosaic: HGTConversion.Mosaic,
                                       flavor: CopernicusDEM.Flavor) throws {
        let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
        let destination = flavor.cachedTile(lat: cell.lat, lon: cell.lon)
        FileTools.removeIfPresent(destination)
        try HGTConversion.write(cell: cell, from: mosaic, to: destination, nodes: flavor.nodes)

        // A cell on the rim of the region has no neighbour to sample its outermost row and
        // column from, and they land in the file as zero; this fills them from inside.
        if let filled = (try? FixHGTEdges.repair(destination)) ?? nil {
            log.append("\(name).hgt: filled \(filled) edge(s)")
        }

        // nodes² samples, two bytes each. A short file means a truncated write, and mkgmap
        // reads it as a wall of zeroes rather than refusing it.
        let expected = flavor.nodes * flavor.nodes * 2
        let size = FileTools.size(of: destination)
        guard size == expected else {
            FileTools.removeIfPresent(destination)
            throw BuildError.missingTool(
                "\(name).hgt came out \(size) bytes, expected \(expected)")
        }
    }
}
