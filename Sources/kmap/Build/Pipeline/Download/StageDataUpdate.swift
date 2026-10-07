import Foundation

/// Stage 2: the data packs a build reads but never builds - the coastlines, and the
/// boundaries an address is written from. One the build asks for and does not find is
/// fetched here, once, and kept for every build after. One installed sits for months
/// going quietly stale: preflight asks its mirror, and this stage fetches what it found,
/// since 2 GB is not a check.
extension BuildPipeline {
    /// The packs this build reads, installed or not: the coastlines only where it
    /// generates the sea, the boundaries only where it writes an index, since that is
    /// what passes `--bounds`.
    var dataPacksWanted: [DataPack] {
        if let packs = dataPacksForTesting { return packs }
        var wanted: [DataPack] = []
        if recipe.generateSea { wanted.append(.sea) }
        if recipe.searchIndex { wanted.append(.bounds) }
        return wanted
    }

    /// The ones of them installed: what is worth asking a mirror about.
    var dataPacksInUse: [DataPack] { dataPacksWanted.filter(\.isInstalled) }

    /// Asks each mirror whether it has moved on, as often as Settings says to. Never a
    /// reason to stop: an unreachable server leaves the build the pack it already has.
    func checkDataPacks() async {
        let packs = dataPacksInUse
        guard !packs.isEmpty else { return }
        let cadence = settings.settings.toolchainUpdates
        guard cadence != .never else {
            log.append("toolchain updates are off — the packs are used as they are")
            return
        }
        var asked: [String: Date] = [:]
        for pack in packs where !Task.isCancelled && !isCancelled {
            guard !cadence.stillGood(checked: settings.settings.dataChecked[pack.id]) else {
                log.append("\(pack.what) was checked recently — asking again \(cadence.title)")
                continue
            }
            detail(.preflight, t("checking for newer data"))
            let news = await pack.newer()
            asked[pack.id] = Date()
            guard let news else {
                log.append("\(pack.what) is current")
                continue
            }
            state.withLock { $0.pendingPackUpdates.append((pack, news)) }
            log.append("\(pack.what): a newer pack was published — \(news.describedShortly)")
        }
        guard !asked.isEmpty else { return }
        settings.update { stored in
            for (id, when) in asked { stored.dataChecked[id] = when }
        }
    }

    /// Fetches what preflight found. A pack that will not come down is not a failed
    /// build: the one on disk still works, and the log says it was kept. Being cancelled
    /// is not that, and is passed on.
    func updateDataPacks() async throws {
        try stopIfCancelled()
        let missing = dataPacksWanted.filter { !$0.isInstalled }
        guard !pendingPackUpdates.isEmpty || !missing.isEmpty else {
            let cadence = settings.settings.toolchainUpdates
            if dataPacksInUse.isEmpty {
                set(.dataUpdate, .skipped, t("nothing this build reads"))
            } else if cadence == .never {
                set(.dataUpdate, .skipped, t("updates are off"))
            } else {
                set(.dataUpdate, .done, t("up to date"))
            }
            return
        }

        // Or it draws as pending: a bar and a detail line under a dot, no spinner.
        set(.dataUpdate, .running, t("starting"))
        var done: [String] = []
        var kept = false
        var without: [String] = []
        // Asked for by the recipe and not here: whatever the update setting says, since
        // this is a first fetch, not an update.
        for pack in missing {
            do {
                try stopIfCancelled()
                try await fetchDataPack(pack, nil)
                done.append("\(pack.what) · \(Fmt.bytes(FileTools.size(of: pack.file)))")
            } catch {
                try rethrowIfCancelled(error)
                without.append(pack.what)
                log.warn(
                    "could not download \(pack.what) - \(Self.clause(error))."
                        + " Building without it: \(pack.withoutIt)"
                )
            }
        }
        for (pack, news) in pendingPackUpdates {
            do {
                try stopIfCancelled()
                try await fetchDataPack(pack, news)
                done.append("\(pack.what) \(news.describedShortly)")
            } catch {
                // A pack that will not come down is not a failed build. A cancel is, and
                // the stage keeps its running mark so `finish` crosses it out like any
                // other stage the axe fell on.
                try rethrowIfCancelled(error)
                kept = true
                log.warn(
                    "could not update \(pack.what) — \(Self.clause(error))."
                        + " Building with the pack already here"
                )
            }
        }
        pendingPackUpdates.removeAll()
        var line =
            done.isEmpty && kept
            ? t("kept what was already here")
            : done.joined(separator: " · ") + (kept ? " · " + t("one kept") : "")
        if !without.isEmpty {
            let missed = without.map { "\($0): " + t("not downloaded") }.joined(separator: " · ")
            line = line.isEmpty ? missed : line + " · " + missed
        }
        set(.dataUpdate, .done, line)
    }

    /// An error's words as part of a log sentence: without the stop most of them end in.
    private static func clause(_ error: Error) -> String {
        let words = ErrorWords.of(error)
        return words.hasSuffix(".") ? String(words.dropLast()) : words
    }

    /// An update where `news` says what the mirror offers; a first fetch where it is nil.
    private func fetchDataPack(_ pack: DataPack, _ news: DataPack.News?) async throws {
        if let news {
            log.step("updating \(pack.what) — \(Fmt.bytes(news.size))")
        } else {
            log.step("downloading \(pack.what), which this build asks for - kept for every build after")
        }
        beginPhase(.dataUpdate, t("starting"))
        let downloader = Downloader(log: log)
        retain(downloader)

        // Mirrors the downloader's own progress into this stage, as the extract does.
        let (what, board) = (pack.what, board)
        let monitor = Task {
            while !Task.isCancelled {
                let p = downloader.progress
                board.detail(
                    .dataUpdate,
                    "\(what) · " + p.line(secondsLeft: p.eta),
                    fraction: p.fraction
                )
                try? await Task.sleep(nanoseconds: BuildPipeline.progressTick)
            }
        }
        defer { monitor.cancel() }

        try await pack.fetch(
            using: downloader,
            connections: recipe.downloadConnections,
            lastModified: news?.lastModified
        )
        log.ok("\(pack.what) \(news == nil ? "installed" : "updated") — \(Fmt.bytes(FileTools.size(of: pack.file)))")
    }
}
