import Foundation

/// Stage 3: the elevation data every contour and the DEM layer are made from.
///
/// Four sources — Copernicus GeoTIFF, Viewfinder zip archives, SRTM and ALOS through
/// pyhgtmap — all converted to one `.hgt` grid of 3601×3601 nodes per degree.
extension BuildPipeline {
    // MARK: 3 — elevation

    /// Populates the .hgt cache (used by the DEM layer) and, when asked, generates contour
    /// line files. Both come from the same downloaded elevation tiles.
    func buildElevation(extract: URL) async throws -> [URL] {
        guard recipe.needsElevationData else {
            set(.elevation, .skipped, t("not requested"))
            set(.elevationBuild, .skipped, t("not requested"))
            return []
        }
        set(.elevation, .running, t("preparing"))
        Paths.ensure(Paths.hgtCache)

        let bbox = recipe.coverage
        guard bbox.isValid else {
            throw BuildError.noBoundingBox(recipe.mapName)
        }
        await trimElevationCells()
        let expectedTiles = max(1, elevationCells().count)
        log.step("elevation data for \(expectedTiles) × 1° tile(s) from \(recipe.demSources)")
        warnIfCredentialsMissing()

        try await measure(.elevation, "fetch the tiles") {
            try await fetchElevationTiles(covering: bbox)
        }
        // Each source closes the download half as it finishes its own fetching, so this
        // is only the backstop for a source that returned without reaching that point.
        elevationDownloadsFinished()
        elevationBuildStarted("preparing")

        let contourDir = workDirectory.appendingPathComponent("contours", isDirectory: true)
        FileTools.removeIfPresent(contourDir)
        Paths.ensure(contourDir)

        guard recipe.contours else {
            // DEM only: the tiles fetched above are all it needs.
            let count = hgtFileCount()
            guard count > 0 else { throw BuildError.noElevationTiles }
            log.ok("\(count) elevation tile(s) cached for the DEM layer")
            await measure(.elevationBuild, "burn the summits in") {
                await burnPeakElevations(extract: extract)
            }
            set(.elevationBuild, .done, "\(count) elevation tile(s)")
            return []
        }

        // One 1° cell at a time, each into its own reserved id range: splitter requires
        // node ids to ascend across the whole input sequence.

        let cells = contourCells()
        log.append("\(cells.count) cell(s) to contour at \(recipe.contourInterval) m")

        let major = recipe.contourInterval * 10
        let medium = recipe.contourInterval * 5
        // One lane per worker. The tracer is single-threaded, and a lane holds a 26 MB
        // grid plus its working set, so a machine short of memory runs fewer lanes.
        let concurrency = Machine.lanes(max(1, Machine.workers), holdingEach: 0.7)
        if concurrency < max(1, Machine.workers) {
            log.append("\(Machine.memoryGB) GB of memory — tracing \(concurrency) cell(s)"
                       + " at a time rather than \(Machine.workers)")
        }

        try await traceContourCells(cells, into: contourDir, major: major, medium: medium,
                                    concurrency: concurrency)
        try Task.checkCancellation()

        // Sorted by name, which encodes the cell index, so the id ranges ascend.
        let produced = FileTools.contents(of: contourDir).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("contour") && (name.hasSuffix(".pbf") || name.hasSuffix(".osm"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if recipe.contours {
            guard !produced.isEmpty else {
                throw BuildError.noContours(bbox.display)
            }
            let bytes = produced.reduce(Int64(0)) { $0 + FileTools.size(of: $1) }
            log.ok("\(produced.count) contour file(s), \(Fmt.bytes(bytes))")
        }

        if recipe.demLayer {
            let count = hgtFileCount()
            guard count > 0 else {
                throw BuildError.noElevationTiles
            }
            log.ok("\(count) elevation tile(s) cached for the DEM layer")
        }

        // Summits go in after tracing: raising a cell would change the contours there,
        // while the DEM layer reads the tiles as they end up.
        await measure(.elevationBuild, "burn the summits in") {
            await burnPeakElevations(extract: extract)
        }
        set(.elevationBuild, .done,
            recipe.contours ? "\(produced.count) contour file(s)" : "\(hgtFileCount()) elevation tile(s)")
        return produced
    }

    /// Traces every cell's contours, `concurrency` at a time, with a live progress
    /// line. Each cell writes into its own reserved id range, so order changes nothing.
    private func traceContourCells(_ cells: [BBox], into contourDir: URL,
                                   major: Int, medium: Int, concurrency: Int) async throws {
        // The outline every cell's contours are cut to, fetched once for the build.
        let mask = await regionMask()
        let completed = Counter()
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let done = completed.value
                // The conversion is the first fifth of this stage and tracing the rest.
                self.detail(.elevationBuild,
                            "tracing \(done)/\(cells.count) cell(s)",
                            fraction: 0.2 + 0.8 * Double(done) / Double(max(1, cells.count)))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { monitor.cancel() }

        ContourTiming.begin()
        let tracingStarted = Date()
        try await measure(.elevationBuild, "trace the contours") {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0

            func launch(_ index: Int) {
                let cell = cells[index]
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.contourCell(cell, index: index, mask: mask,
                                               directory: contourDir,
                                               major: major, medium: medium)
                    completed.increment()
                }
            }

            while next < cells.count && running < concurrency {
                launch(next); next += 1; running += 1
            }
            while running > 0 {
                try await group.next()
                running -= 1
                // Cancellation is cooperative and the tracer is pure CPU: this is the
                // one point, between cells, where it can take effect.
                try Task.checkCancellation()
                if next < cells.count { launch(next); next += 1; running += 1 }
            }
        }
        }
        for line in ContourTiming.report(wall: Date().timeIntervalSince(tracingStarted),
                                         lanes: concurrency) {
            log.debug(line, stage: StageID.elevationBuild.rawValue)
        }
    }

    /// Which of the three ways elevation arrives.
    enum Source { case copernicus, viewfinder, credentialed }

    /// Nothing more is going to be fetched after this source.
    func isLastFetching(_ source: Source) -> Bool {
        switch source {
        case .copernicus: return viewfinderResolutions.isEmpty && credentialedSources.isEmpty
        case .viewfinder: return credentialedSources.isEmpty
        case .credentialed: return true
        }
    }

    /// Closes the download half. Guarded, because several sources reach it and only the
    /// first arrival should stop that stage's clock.
    func elevationDownloadsFinished() {
        guard status(of: .elevation) == .running else { return }
        set(.elevation, .done, "\(hgtFileCount()) elevation tile(s)")
    }

    /// Opens the processing half, whether or not anything is still downloading.
    func elevationBuildStarted(_ detail: String) {
        guard status(of: .elevationBuild) != .running else { return }
        set(.elevationBuild, .running, detail)
    }
}
