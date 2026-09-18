import Foundation

/// The annotate pass, run over every extract before the splitter: barriers
/// classified by the way they stand on, redundant descriptions dropped, road ends
/// repaired, contours folded in.
extension BuildPipeline {
    /// The share of the split stage's bar the annotation pass takes; the splitter's own
    /// phases walk the rest.
    static let splitAnnotateShare = 0.45

    /// Annotates every extract at once, as many as memory allows, and returns the
    /// files the splitter should read. Only the first region folds the contours in.
    func annotateExtracts(_ extracts: [URL],
                                  contoursTask: Task<[URL], Error>) async throws -> [String] {
        // Announced once for the whole group; the per-region lines carry a prefix.
        if recipe.needsBarrierContext || recipe.descriptions != .off
            || (recipe.healRoadEnds && recipe.routable) {
            log.step(recipe.healRoadEnds && recipe.routable
                     ? "classifying barriers, and repairing road ends OSM left short"
                     + " — \(extracts.count) region(s) at once"
                     : (recipe.descriptions != .off && !recipe.needsBarrierContext
                        ? "removing descriptions that only repeat the name"
                        + " — \(extracts.count) region(s) at once"
                        : "classifying barriers, and tidying descriptions"
                        + " — \(extracts.count) region(s) at once"))
        }
        // At most three passes at once, fewer on a small machine: a pass holds its
        // extract's node table, roads and barriers, roughly 14x the extract's size.
        let largest = extracts.map { FileTools.size(of: $0) }.max() ?? 0
        let atOnce = Machine.lanes(3, holdingEach: Double(largest) * 14 / 1_073_741_824)
        if atOnce < min(3, extracts.count) {
            log.append("\(Machine.memoryGB) GB of memory — annotating"
                       + " \(atOnce == 1 ? "one region" : "\(atOnce) regions") at a time")
        }
        var results = [[String]](repeating: [], count: extracts.count)
        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let extract = extracts[index]
                group.addTask { [weak self] in
                    guard let self else { return (index, []) }
                    // Only the first region folds the contours in, and only its write
                    // needs them, so its scan overlaps with the tracer.
                    return (index, try await self.annotateBarriersIfNeeded(
                        extract,
                        contoursReady: index == 0 ? { try await contoursTask.value } : nil,
                        suffix: extracts.count > 1 ? "-\(index)" : "",
                        regionIndex: index))
                }
                next += 1
                running += 1
            }
            while next < extracts.count && running < atOnce { launch(next) }
            var done = 0
            while running > 0 {
                if let (index, files) = try await group.next() {
                    results[index] = files
                }
                running -= 1
                done += 1
                advance(.split, fraction: Double(done) / Double(extracts.count)
                        * Self.splitAnnotateShare)
                if next < extracts.count { launch(next) }
            }
        }
        return results.flatMap { $0 }
    }

    /// Rewrites one extract with what mkgmap's rule language cannot express: barriers
    /// classified by the way they stand on, redundant descriptions dropped, road ends
    /// repaired, contours folded in. Returns the files the splitter should read.
    private func annotateBarriersIfNeeded(_ extract: URL,
                                          contoursReady: (() async throws -> [URL])? = nil,
                                          suffix: String = "",
                                          regionIndex: Int = 0) async throws -> [String] {
        let dropDuplicates = recipe.descriptions != .off
        let heal = recipe.healRoadEnds && recipe.routable
        let features = recipe.needsBarrierContext || dropDuplicates || heal
        // With no feature switched on the pass only folds the contours in, so there is no
        // scan to overlap with the tracer.
        var contours: [URL] = []
        if !features {
            contours = try await contoursReady?() ?? []
            guard !contours.isEmpty else { return [extract.path] }
        }

        let annotated = workDirectory.appendingPathComponent("annotated\(suffix).osm.pbf")
        FileTools.removeIfPresent(annotated)
        // With several regions the caller has already announced the step for all of them.
        if suffix.isEmpty {
            log.step(heal
                     ? "classifying barriers, and repairing road ends OSM left short"
                     : (dropDuplicates && !recipe.needsBarrierContext
                        ? "removing descriptions that only repeat the name"
                        : "classifying barriers, and tidying descriptions"))
        }

        var pass = AnnotatePass(source: extract, destination: annotated)
        pass.contours = contours
        pass.markDuplicateVenues = true
        pass.dropDuplicateDescriptions = dropDuplicates
        if heal {
            pass.repairRadius = recipe.healRadius
            // A low obstacle between the ends is crossed by a link of its own rather than
            // a shared node; a building or fence is never crossed.
            pass.bridgeObstacles = true
            // The link is named in the map's own alphabet, saying what was crossed.
            pass.language = recipe.codePage == 1251 ? "ru" : "en"
            // The DEM distinguishes a slope from a face, so an end above a drop is left
            // alone. Present only where the contour step already fetched it.
            pass.dem = CopernicusDEM.cacheDirectory
            // Each region's pass invents ids from its own 2^32 range, or the ids collide
            // once the annotated files are merged into one splitter stream.
            pass.inventedIDBase = (1 << 40) + Int64(regionIndex) << 32
        }

        // With several regions running at once their log lines interleave, so each is
        // prefixed with the region it came from.
        let prefix = suffix.isEmpty ? "" : "region \(regionIndex + 1): "
        do {
            if features {
                // The async variant starts the scans now and awaits the contours only at
                // the point the folding begins.
                _ = try await pass.run(contoursReady: contoursReady ?? { [] }) {
                    self.log.append(prefix + $0)
                    self.detail(.split, prefix + $0)
                }
            } else {
                _ = try pass.run {
                    self.log.append(prefix + $0)
                    self.detail(.split, prefix + $0)
                }
            }
        } catch {
            try rethrowIfCancelled(error)
            log.warn("annotation failed (\(error)) — building without it")
            let fallback = try await contoursReady?() ?? contours
            return [extract.path] + fallback.map(\.path)
        }
        guard FileTools.exists(annotated), FileTools.size(of: annotated) > 0 else {
            log.warn("annotation produced nothing — building without the barrier split")
            return [extract.path] + contours.map(\.path)
        }
        return [annotated.path]
    }

    /// Reads splitter's `template.args` for the per-tile mkgmap arguments and `areas.list`
    /// for each tile's bounds, which decide what goes in which output file.
}
