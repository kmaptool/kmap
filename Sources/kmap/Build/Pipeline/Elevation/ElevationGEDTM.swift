import Foundation

/// GEDTM30: the tiles of 1 huge file that the cells need, fetched by range in lanes and
/// written straight onto the arc-second grid.

extension BuildPipeline {
    /// Fetches only the tiles under the wanted cells and writes each cell as `.hgt`.
    func fetchGEDTMTiles(_ source: GEDTM30, covering bbox: BBox, last: Bool) async throws {
        Paths.ensure(source.cacheDirectory)
        let all = elevationCells()
        let earlier = earlierSourceDirectories(before: source.sourceID)
        let wanted = all.filter { !cellSettledEarlier(earlier, lat: $0.lat, lon: $0.lon) }
        if wanted.count < all.count {
            log.append(
                "\(all.count - wanted.count) cell(s) already held by an earlier"
                    + " source — this one fills the \(wanted.count) left"
            )
        }
        guard !wanted.isEmpty else {
            log.append("nothing left for \(source.sourceID) — every cell is already held")
            return
        }
        let unconverted = wanted.filter { !source.isDone(lat: $0.lat, lon: $0.lon) }
        guard !unconverted.isEmpty else {
            log.append("all \(wanted.count) \(source.label) cell(s) already done")
            return
        }

        source.dropStaleChunks()
        log.step("reading the \(source.label) tile index")
        let read = source.remote()
        let layout = try await GEDTM30.parsing { try await GEDTM30.layout(read: read) }
        var needs: [(cell: (lat: Int, lon: Int), tiles: [Int])] = []
        for cell in unconverted {
            let tiles = try layout.tiles(lat: cell.lat, lon: cell.lon, nodes: source.nodes)
            if tiles.isEmpty {
                // Remembered, so a rebuild skips the index.
                try? source.leave(source.outsideMark(lat: cell.lat, lon: cell.lon))
            } else {
                needs.append((cell, tiles))
            }
        }
        if needs.count < unconverted.count {
            log.append("\(unconverted.count - needs.count) cell(s) lie outside \(source.label), 65S to 85N")
        }
        let under = Set(needs.flatMap(\.tiles))
        let spans = try await GEDTM30.parsing { try await GEDTM30.spans(of: under, in: layout, read: read) }
        // A chunk on disk is whole: it is moved in only once complete.
        let missing = spans.filter { $0.value.count > 0 && !FileTools.exists(source.chunk($0.value)) }
            .sorted { $0.key < $1.key }
        let weight = missing.reduce(0) { $0 + $1.value.count }
        log.step("fetching \(missing.count) \(source.label) tile(s), \(Fmt.bytes(Int64(weight)))")
        try await downloadGEDTMChunks(missing.map { ($0.key, $0.value) }, source: source)

        if last { elevationDownloadsFinished() }
        elevationBuildStarted("converting")
        let outcome = try await convertGEDTMCells(needs, layout: layout, spans: spans, source: source)

        // A chunk goes once no cell that needs it is left unconverted.
        let kept = Set(outcome.failed.flatMap(\.tiles))
        for (tile, span) in spans where !kept.contains(tile) {
            FileTools.removeIfPresent(source.chunk(span))
        }
        log.ok(
            "\(outcome.converted) \(source.label) tile(s) converted"
                + (outcome.sea > 0 ? ", \(outcome.sea) open sea" : "")
        )
        if outcome.converted == 0, Self.endsWithNoTiles(last: last, onHand: hgtFileCount()) {
            throw BuildError.noElevationTiles
        }
    }

    /// Downloads the chunks, several at a time, with a live progress line.
    private func downloadGEDTMChunks(_ chunks: [(tile: Int, span: GEDTM30.Span)], source: GEDTM30) async throws {
        guard !chunks.isEmpty else { return }
        Paths.ensure(source.chunkDirectory)
        let lanes = max(2, min(6, Machine.workers))
        let fetched = Counter()
        let flight = Flight()
        let started = Date()
        let (total, board) = (chunks.count, board)
        let monitor = Task {
            var pace = Pace()
            while !Task.isCancelled {
                let done = fetched.value
                pace.note(done: done)
                let text = BuildPipeline.fetchLine(
                    source: source.label,
                    done: done,
                    of: total,
                    received: flight.received,
                    elapsed: Date().timeIntervalSince(started),
                    secondsLeft: pace.secondsLeft(total - done)
                )
                board.detail(.elevation, text, fraction: Double(done) / Double(max(1, total)))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { monitor.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let span = chunks[index].span
                group.addTask { [weak self] in
                    guard let self else { return }
                    let downloader = Downloader(log: self.log)
                    flight.joined(downloader)
                    do {
                        try await downloader.download(
                            url: source.url,
                            from: span.offset,
                            count: Int64(span.count),
                            to: source.chunk(span)
                        )
                        flight.left(downloader, carrying: Int64(span.count))
                        fetched.increment()
                    } catch {
                        flight.left(downloader, carrying: 0)
                        throw error
                    }
                }
                running += 1
                next += 1
            }
            while next < chunks.count && running < lanes { launch(next) }
            while running > 0 {
                try await group.next()
                running -= 1
                if next < chunks.count { launch(next) }
            }
        }
    }

    /// Writes the cells on every core. Each decodes its own tiles: 1 tile per lane, where a
    /// shared cache over a wide region would hold gigabytes.
    private func convertGEDTMCells(
        _ needs: [(cell: (lat: Int, lon: Int), tiles: [Int])],
        layout: GEDTM30.Layout,
        spans: [Int: GEDTM30.Span],
        source: GEDTM30
    ) async throws -> (converted: Int, sea: Int, failed: [(cell: (lat: Int, lon: Int), tiles: [Int])]) {
        let converted = Counter()
        let sea = Counter()
        let done = Counter()
        let failed = Locked<[Int]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch(_ index: Int) {
                let (cell, _) = needs[index]
                group.addTask { [weak self] in
                    guard let self else { return }
                    let name = HGTName.of(lat: cell.lat, lon: cell.lon)
                    let destination = source.cachedTile(lat: cell.lat, lon: cell.lon)
                    do {
                        let ground = try source.write(lat: cell.lat, lon: cell.lon, layout: layout, to: destination) {
                            tile in
                            guard let span = spans[tile], span.count > 0 else { return nil }
                            // A chunk that does not decode is fetched again next time.
                            do {
                                let data = try Data(contentsOf: source.chunk(span))
                                guard data.count == span.count else { throw GEDTM30.Trouble.truncated }
                                return try GEDTM30.decode(data, layout: layout)
                            } catch {
                                FileTools.removeIfPresent(source.chunk(span))
                                throw error
                            }
                        }
                        if ground > 0 {
                            converted.increment()
                        } else {
                            try source.leave(source.seaMark(lat: cell.lat, lon: cell.lon))
                            sea.increment()
                        }
                    } catch {
                        FileTools.removeIfPresent(destination)
                        failed.withLock { $0.append(index) }
                        self.log.warn("\(name): could not be converted — \(error)")
                    }
                    done.increment()
                    self.detail(
                        .elevationBuild,
                        "converting \(done.value)/\(needs.count)",
                        fraction: Double(done.value) / Double(max(1, needs.count)) * 0.2
                    )
                }
                next += 1
                running += 1
            }
            while next < needs.count && running < max(1, Machine.workers) { launch(next) }
            while running > 0 {
                try await group.next()
                running -= 1
                try Task.checkCancellation()
                if next < needs.count { launch(next) }
            }
        }
        let lost = failed.withLock { $0 }.map { needs[$0] }
        return (converted.value, sea.value, lost)
    }
}

extension GEDTM30 {
    /// Removes chunks untouched for a week.
    func dropStaleChunks() {
        let old = Date().addingTimeInterval(-7 * 86400)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: chunkDirectory.path) else { return }
        for name in names {
            let file = chunkDirectory.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let modified, modified < old { FileTools.removeIfPresent(file) }
        }
    }
}
