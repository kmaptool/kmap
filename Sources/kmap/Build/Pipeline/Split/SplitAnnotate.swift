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
    func annotateExtracts(
        _ extracts: [URL],
        contoursTask: Task<[URL], Error>,
        terrain: Gate<[URL]>
    ) async throws -> [String] {
        // Announced once for the whole group; the per-region lines carry a prefix. A
        // single region announces itself.
        if extracts.count > 1, let step = annotateStep(foldsContours: recipe.contours) {
            log.step(step + " — \(extracts.count) region(s) at once")
        }
        // At most three passes at once, fewer on a small machine: a pass holds its
        // extract's node table, roads and barriers, roughly 14x the extract's size.
        let largest = extracts.map { FileTools.size(of: $0) }.max() ?? 0
        let atOnce = Machine.lanes(3, holdingEach: Double(largest) * 14 / 1_073_741_824)
        if atOnce < min(3, extracts.count) {
            log.append(
                "\(Machine.memoryGB) GB of memory — annotating"
                    + " \(atOnce == 1 ? "one region" : "\(atOnce) regions") at a time"
            )
        }
        // Each region's files go to its own place, not back through the group: see
        // `ExtractLocator.newestAnswering`.
        let results = Locked([[String]](repeating: [], count: extracts.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let extract = extracts[index]
                // Only the first region folds the contours in, and only its write needs
                // them, so its scan overlaps with the tracer.
                let contours: (@Sendable () async throws -> [URL])?
                if index == 0 {
                    contours = { [board] in
                        try await board.waiting(.split) {
                            try await contoursTask.value
                        }
                    }
                } else {
                    contours = nil
                }
                // A lane of the split while it runs: the stage reads as waiting only when
                // every region at work waits. Ended below, once the next region has taken
                // the lane over, so the count never dips between 2 regions.
                board.beginLane(.split)
                group.addTask { [weak self] in
                    guard let self else { return }
                    let files = try await self.annotateBarriersIfNeeded(
                        extract,
                        contoursReady: contours,
                        terrain: terrain,
                        suffix: extracts.count > 1 ? "-\(index)" : "",
                        regionIndex: index
                    )
                    results.withLock { $0[index] = files }
                }
                next += 1
                running += 1
            }
            while next < extracts.count && running < atOnce { launch(next) }
            var done = 0
            // A region that throws ends the split: the lanes still begun end with it.
            defer { for _ in 0..<running { board.endLane(.split) } }
            while running > 0 {
                try await group.next()
                running -= 1
                done += 1
                advance(
                    .split,
                    fraction: Double(done) / Double(extracts.count)
                        * Self.splitAnnotateShare
                )
                if next < extracts.count { launch(next) }
                board.endLane(.split)
            }
        }
        return results.withLock { $0 }.flatMap { $0 }
    }

    /// What the annotate step says it does; nil where it has nothing to do.
    private func annotateStep(foldsContours: Bool) -> String? {
        if recipe.healRoadEnds && recipe.routable {
            return "classifying barriers, and repairing road ends OSM left short"
        }
        if recipe.needsBarrierContext {
            return "classifying barriers, and tidying descriptions"
        }
        if recipe.descriptions != .off {
            return "removing descriptions that only repeat the name"
        }
        if foldsContours { return "folding the contours in" }
        return recipe.codePage != CodePage.utf8 ? "taking out of labels what the code page lacks" : nil
    }

    /// Rewrites one extract with what mkgmap's rule language cannot express: barriers
    /// classified by the way they stand on, redundant descriptions dropped, road ends
    /// repaired, contours folded in. Returns the files the splitter should read.
    private func annotateBarriersIfNeeded(
        _ extract: URL,
        contoursReady: (@Sendable () async throws -> [URL])? = nil,
        terrain: Gate<[URL]>,
        suffix: String = "",
        regionIndex: Int = 0
    ) async throws -> [String] {
        let dropDuplicates = recipe.descriptions != .off
        let heal = recipe.healRoadEnds && recipe.routable
        let features = recipe.needsBarrierContext || dropDuplicates || heal
        // A Unicode map draws what a code page cannot.
        let cleans = recipe.codePage != CodePage.utf8
        // With no feature switched on the pass only folds the contours in and cleans the
        // labels, so there is no scan to overlap with the tracer.
        var contours: [URL] = []
        if !features {
            contours = try await contoursReady?() ?? []
            guard !contours.isEmpty || cleans else { return [extract.path] }
        }

        let annotated = workDirectory.appendingPathComponent("annotated\(suffix).osm.pbf")
        FileTools.removeIfPresent(annotated)
        // With several regions the caller has already announced the step for all of them.
        if suffix.isEmpty {
            if let step = annotateStep(foldsContours: !contours.isEmpty) { log.step(step) }
        }

        var pass = AnnotatePass(source: extract, destination: annotated)
        pass.shouldStop = stopAsked
        pass.contours = contours
        pass.markDuplicateVenues = true
        pass.dropDuplicateDescriptions = dropDuplicates
        pass.cleanLabels = cleans
        pass.keepsJoiners = recipe.codePage == CodePage.arabic
        if heal {
            pass.repairRadius = recipe.healRadius
            // A low obstacle between the ends is crossed by a link of its own rather than
            // a shared node; a building or fence is never crossed.
            pass.bridgeObstacles = true
            // The link is named in the map's own alphabet, saying what was crossed.
            pass.language = recipe.speaksRussian ? "ru" : "en"
            // The DEM tells a slope from a face. Read from the DEM layer's tiles once fetched, so
            // a first build and a rebuild repair alike.
            pass.demReady = { await terrain.value }
            pass.demAtHand = { terrain.opened }
            // Shown as waiting only once nothing else of this extract is being read, and
            // the stage only once every region at work waits.
            pass.onHeld = { [board] held in
                if held { board.beginWaiting(.split) } else { board.endWaiting(.split) }
            }
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
            // A full disk fails the build rather than a map without its repairs.
            if FileTools.isOutOfSpace(error) { throw error }
            // Asked first: an elevation that failed fails the build, which then does not go on
            // without the annotation.
            let fallback = try await contoursReady?() ?? contours
            log.warn("annotation failed (\(ErrorWords.of(error))) — building without it")
            return [extract.path] + fallback.map(\.path)
        }
        guard FileTools.exists(annotated), FileTools.size(of: annotated) > 0 else {
            log.warn("annotation produced nothing — building without the barrier split")
            // With features on the contours were the pass's to fold in; they still go.
            let fallback = try await contoursReady?() ?? contours
            return [extract.path] + fallback.map(\.path)
        }
        return [annotated.path]
    }

    /// Reads splitter's `template.args` for the per-tile mkgmap arguments and `areas.list`
    /// for each tile's bounds, which decide what goes in which output file.
}
