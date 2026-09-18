import Foundation

/// Stage 2: the data packs a build reads but never builds — the coastlines, and the
/// boundaries an address is written from. Installed once, they then sit for months going
/// quietly stale. Preflight asks the mirror; this stage fetches what it found, since
/// 2 GB is not a check.
extension BuildPipeline {

    /// The packs this build reads: the coastlines only where it generates the sea, the
    /// boundaries only where it writes an index, since that is what passes `--bounds`.
    /// What is not installed is not installed — the toolchain screen decides that.
    var dataPacksInUse: [DataPack] {
        var wanted: [DataPack] = []
        if recipe.generateSea { wanted.append(.sea) }
        if recipe.searchIndex { wanted.append(.bounds) }
        return wanted.filter(\.isInstalled)
    }

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
            pendingPackUpdates.append((pack, news))
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
        guard !pendingPackUpdates.isEmpty else {
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
                log.warn("could not update \(pack.what) — \(error.localizedDescription)."
                         + " Building with the pack already here")
            }
        }
        pendingPackUpdates.removeAll()
        set(.dataUpdate, .done,
            done.isEmpty ? t("kept what was already here")
                : done.joined(separator: " · ") + (kept ? " · " + t("one kept") : ""))
    }

    private func fetchDataPack(_ pack: DataPack, _ news: DataPack.News) async throws {
        log.step("updating \(pack.what) — \(Fmt.bytes(news.size))")
        beginPhase(.dataUpdate, t("starting"))
        let downloader = Downloader(log: log)
        retain(downloader)

        // Mirrors the downloader's own progress into this stage, as the extract does.
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = downloader.progress
                let text = "\(pack.what) · \(Fmt.bytes(p.received)) / \(Fmt.bytes(p.total))"
                    + "  ·  \(Fmt.rate(p.rate))"
                    + (p.eta.isFinite ? "  ·  \(Fmt.duration(p.eta)) left" : "")
                self.detail(.dataUpdate, text, fraction: p.fraction)
                try? await Task.sleep(nanoseconds: BuildPipeline.progressTick)
            }
        }
        defer { monitor.cancel() }

        try await pack.fetch(using: downloader, connections: recipe.downloadConnections,
                             lastModified: news.lastModified)
        log.ok("\(pack.what) updated — \(Fmt.bytes(FileTools.size(of: pack.file)))")
    }
}
