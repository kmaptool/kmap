import Foundation

/// The sources published as a GeoTIFF per degree (Copernicus, FABDEM): downloaded in
/// lanes and resampled onto the arc-second grid.

extension BuildPipeline {
    /// Downloads the source's tiles covering the region and converts each to `.hgt`.
    ///
    /// A missing tile is not an error: the source simply has nothing over open sea, and a
    /// coastal region routinely asks for degrees that are entirely water.
    func fetchDEMTiles<Source: DEMTileSource>(
        _ flavor: Source,
        covering bbox: BBox,
        last: Bool
    ) async throws {
        Paths.ensure(flavor.cacheDirectory)

        // A cell a finer source listed before this one already converted is settled: the
        // DEM and the contours would take that copy anyway. What remains here is this
        // source's own share — the gaps.
        let all = elevationCells()
        let earlier = earlierSourceDirectories(before: flavor.sourceID)
        let wanted = all.filter { !cellSettledEarlier(earlier, lat: $0.lat, lon: $0.lon) }
        // A source with nothing to do says so only in the detailed log.
        guard !wanted.isEmpty else {
            log.debug("nothing left for \(flavor.sourceID) — every cell is already held")
            return
        }
        if wanted.count < all.count {
            log.append(
                "\(all.count - wanted.count) cell(s) already held by an earlier"
                    + " source — this one fills the \(wanted.count) left"
            )
        }

        // Three cell states: a finished .hgt needs nothing, a cached .tif skips straight
        // to conversion, and only the rest go over the network.
        let unconverted = wanted.filter { !FileTools.exists(flavor.cachedTile(lat: $0.lat, lon: $0.lon)) }
        guard !unconverted.isEmpty else {
            log.debug("all \(wanted.count) \(flavor.label) tile(s) already converted")
            return
        }
        let scratch = flavor.tifCacheDirectory
        Paths.ensure(scratch)
        let missing = unconverted.filter {
            !FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        if missing.count < unconverted.count {
            log.append(
                "\(unconverted.count - missing.count) \(flavor.label) tile(s) already downloaded — kept from an interrupted run"
            )
        }
        // Cells the source's list lacks are sea and not asked for, so a cached build works
        // offline.
        let list = await ElevationCost.tileCoverage(flavor)
        let (asked, unpublished) = Self.published(missing, in: list)
        if unpublished > 0 {
            log.append("\(unpublished) cell(s) \(flavor.label) does not publish, sea or beyond it — not asked for")
        }
        if !asked.isEmpty { log.step("fetching \(asked.count) \(flavor.label) tile(s)") }

        // Two phases: downloads run several at a time, then conversion warps from a mosaic
        // of all the tiles. A `.hgt` grid is half a cell wider than the source square on
        // every side, so its outer nodes need the neighbour's data to sample.
        let absent =
            unpublished
            + (asked.isEmpty ? 0 : try await downloadDEMTifs(asked, flavor: flavor, into: scratch, listed: list != nil))

        let downloaded = unconverted.filter {
            FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        guard !downloaded.isEmpty else {
            log.ok("no \(flavor.label) tiles here — \(absent) cell(s) are open sea")
            if Self.endsWithNoTiles(last: last, onHand: mapHGTCount()) { throw BuildError.noElevationTiles }
            return
        }

        // One mosaic over every tile just downloaded, so a node on a tile's rim samples
        // its neighbour rather than leaving a column of zeros down the join.
        let mosaic = HGTConversion.Mosaic(converting: downloaded) { lat, lon in
            let file = flavor.downloadedTif(lat: lat, lon: lon)
            return FileTools.exists(file) ? file : nil
        }

        // Downloading is over for this source; the download half closes only when nothing
        // else is going to fetch. The two halves overlap across sources.
        if last { elevationDownloadsFinished() }
        elevationBuildStarted("converting")
        let converted = try await convertDEMTiles(
            downloaded,
            from: mosaic,
            flavor: flavor
        )

        // The mosaic samples across the joins, so no .tif is deleted until the whole pass
        // is over, and a cell whose conversion failed keeps its download: unless its own
        // file would not read, which kept would fail every build after this one too.
        for cell in downloaded {
            let tif = flavor.downloadedTif(lat: cell.lat, lon: cell.lon)
            if FileTools.exists(flavor.cachedTile(lat: cell.lat, lon: cell.lon)) {
                FileTools.removeIfPresent(tif)
            } else if let failure = mosaic.failure(lat: cell.lat, lon: cell.lon), GeoTIFF.Trouble.isDamage(failure) {
                log.warn("\(tif.lastPathComponent) would not read — it is fetched again on the next build")
                FileTools.removeIfPresent(tif)
            }
        }

        log.ok(
            "\(converted) \(flavor.label) tile(s) converted"
                + (absent > 0 ? ", \(absent) not in the bucket (open sea)" : "")
        )
        if converted == 0, Self.endsWithNoTiles(last: last, onHand: mapHGTCount()) {
            throw BuildError.noElevationTiles
        }
    }

    /// The cells the source's list names, and how many it lacks; all of them with no list.
    static func published(
        _ cells: [(lat: Int, lon: Int)],
        in list: Set<String>?
    ) -> (asked: [(lat: Int, lon: Int)], unpublished: Int) {
        guard let list else { return (cells, 0) }
        let asked = cells.filter { list.contains(HGTName.of(lat: $0.lat, lon: $0.lon)) }
        return (asked, cells.count - asked.count)
    }

    /// Only the last source, with no tile on hand, ends the build; an earlier one leaves
    /// the gaps to the next.
    static func endsWithNoTiles(last: Bool, onHand: Int) -> Bool {
        last && onHand == 0
    }

    /// Downloads the missing tiles, several at a time, with a live progress line. A tile
    /// the source does not hold is open sea, not a failure, unless `listed`: the cells
    /// come from the source's own list, so a refusal is warned of and not counted as sea.
    ///
    /// - Returns: how many cells came back absent.
    private func downloadDEMTifs<Source: DEMTileSource>(
        _ missing: [(lat: Int, lon: Int)],
        flavor: Source,
        into scratch: URL,
        listed: Bool
    ) async throws -> Int {
        let lanes = max(2, min(6, Machine.workers))
        let absent = Counter()
        let refused = Counter()
        let fetched = Counter()
        // Several tiles are in flight at once, so no single downloader knows the total
        // rate; this adds them up.
        let flight = Flight()
        let started = Date()

        // How fast tiles have been finishing lately rather than on average since the
        // start: a burst of early arrivals skews an average badly. See `Pace`.
        let (total, board) = (missing.count, board)
        let monitor = Task {
            var pace = Pace()
            while !Task.isCancelled {
                let done = fetched.value + absent.value + refused.value
                pace.note(done: done)
                let text = BuildPipeline.fetchLine(
                    source: flavor.family,
                    done: done,
                    of: total,
                    received: flight.received,
                    elapsed: Date().timeIntervalSince(started),
                    secondsLeft: pace.secondsLeft(total - done)
                )
                board.detail(
                    .elevation,
                    text,
                    fraction: Double(done) / Double(max(1, total))
                )
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
                    let name = HGTName.of(lat: cell.lat, lon: cell.lon)
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
                        // Under the shared lock, and skipped where another kmap got it first.
                        let lock = try await downloader.holdingDownload(of: assembling)
                        defer { withExtendedLifetime(lock) {} }
                        if FileTools.exists(tif) || FileTools.exists(flavor.cachedTile(lat: cell.lat, lon: cell.lon)) {
                            flight.left(downloader, carrying: 0)
                            fetched.increment()
                            return
                        }
                        // Two connections per tile: with several tiles in flight the link
                        // is already busy, and the bucket favours plain GETs.
                        try await downloader.download(url: url, to: assembling, connections: 2, lockHeld: true)
                        try FileTools.move(assembling, to: tif)
                        flight.left(downloader, carrying: FileTools.size(of: tif))
                        fetched.increment()
                    } catch let error where flavor.isAbsent(error) {
                        flight.left(downloader, carrying: 0)
                        // Nothing in the bucket means open sea, which is not a failure. A
                        // cell the source's own list names is there: refused, it is said
                        // and left to the sources after this one, and asked again next time.
                        if listed {
                            refused.increment()
                            self.log.warn("\(name): the source lists it but refused it (\(error)) — not open sea")
                        } else {
                            absent.increment()
                        }
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
    private func convertDEMTiles<Source: DEMTileSource>(
        _ downloaded: [(lat: Int, lon: Int)],
        from mosaic: HGTConversion.Mosaic,
        flavor: Source
    ) async throws -> Int {
        let converted = Counter()
        let done = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let cell = downloaded[index]
                group.addTask { [weak self] in
                    guard let self else { return }
                    let name = HGTName.of(lat: cell.lat, lon: cell.lon)
                    do {
                        try self.convertDEMTile(cell, from: mosaic, flavor: flavor)
                        converted.increment()
                    } catch {
                        self.log.warn("\(name): could not be converted — \(error)")
                    }
                    done.increment()
                    self.detail(
                        .elevationBuild,
                        "converting \(done.value)/\(downloaded.count)",
                        fraction: Double(done.value) / Double(max(1, downloaded.count)) * 0.2
                    )
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
    func convertDEMTile<Source: DEMTileSource>(
        _ cell: (lat: Int, lon: Int),
        from mosaic: HGTConversion.Mosaic,
        flavor: Source
    ) throws {
        try landHGT(cell, from: mosaic, to: flavor.cachedTile(lat: cell.lat, lon: cell.lon), nodes: flavor.nodes)
    }

    /// Writes 1 cell's `.hgt` from the mosaic beside the cache, edges and all, then moves
    /// it in: existing means done, to a later build and to another kmap reading the cache.
    func landHGT(
        _ cell: (lat: Int, lon: Int),
        from mosaic: HGTConversion.Mosaic,
        to destination: URL,
        nodes: Int
    ) throws {
        let name = HGTName.of(lat: cell.lat, lon: cell.lon)
        let directory = destination.deletingLastPathComponent()
        // Another kmap sharing the cache converted it since this one looked, and may have
        // let its download go: what it wrote stays, and is not written over from nothing.
        guard !FileTools.exists(destination) else {
            mosaic.release(cellLat: cell.lat, cellLon: cell.lon)
            return
        }
        // One a killed run left goes after an hour.
        SweptOnce.sweep(directory) { Self.removeAbandonedParts(in: $0) }
        let making = directory.appendingPathComponent("\(name).hgt.\(UUID().uuidString.prefix(8)).part")
        defer { FileTools.removeIfPresent(making) }
        try HGTConversion.write(cell: cell, from: mosaic, to: making, nodes: nodes)
        mosaic.release(cellLat: cell.lat, cellLon: cell.lon)

        // A cell on the rim of the region has no neighbour to sample its outermost row and
        // column from, and they land in the file as zero; this fills them from the cached
        // neighbour, or from inside.
        if let filled = (try? FixHGTEdges.repair(making, cell: cell, in: directory)) ?? nil {
            log.append("\(name).hgt: filled \(filled) edge(s)")
        }

        // nodes * nodes samples, 2 bytes each. A short file means a truncated write, and mkgmap
        // reads it as a wall of zeroes rather than refusing it.
        let expected = nodes * nodes * 2
        let size = FileTools.size(of: making)
        guard size == expected else {
            throw BuildError.missingTool(
                "\(name).hgt came out \(size) bytes, expected \(expected)"
            )
        }
        // Another kmap may have moved its own in meanwhile: the same tile, kept.
        do {
            try FileTools.move(making, to: destination)
        } catch {
            if !FileTools.exists(destination) { throw error }
            return
        }
        let refreshed = FixHGTEdges.refreshNeighbours(of: destination, cell: cell, in: directory)
        if !refreshed.isEmpty {
            log.append("\(name).hgt: edge shared with \(refreshed.joined(separator: ", ")) made to agree")
        }
    }

    /// Cells a killed conversion left half made, `N45E006.hgt.<hex>.part`, an hour old so
    /// another kmap's in hand stays.
    static func removeAbandonedParts(in directory: URL, now: Date = Date()) {
        let entries =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "part" && entry.lastPathComponent.contains(".hgt.") {
            guard let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 3600 else { continue }
            FileTools.removeIfPresent(entry)
        }
    }
}
