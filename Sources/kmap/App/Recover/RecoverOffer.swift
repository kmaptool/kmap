import Foundation

/// The download offer: which region recover would read next, what it weighs, and fetching
/// it into the cache a build reads.
extension RecoverScreen {
    /// Offers the region to download after a run that was refused. `short` is a run that
    /// had ground, and too little: with no region left it goes on with what there is.
    func offer(_ ctx: AppContext, frame: BBox, short: Bool) {
        let index = ctx.index
        let img = img

        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if index.regions.isEmpty { try await index.load() }
                let next = await RegionSuggestion.nextGround(for: img, index: index, asking: true)
                await MainActor.run {
                    // Esc while the size was asked: no dialog, and a screen Esc can leave.
                    guard self.work?.isCancelled != true else { return self.stopped() }
                    if !next.picks.isEmpty {
                        self.present(next.picks)
                    } else if short {
                        self.anyGround = true
                        self.start(ctx)
                    } else {
                        self.fail(
                            saying: next.reached
                                ? t(
                                    "the extracts kmap holds around this map do not cover what it draws (%@)",
                                    frame.display
                                )
                                : t("no region kmap can download overlaps this map (%@)", frame.display)
                        )
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self.stopped() }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    /// The region to offer after a run that went through: the one that may settle the
    /// most of the codes it left unsettled, nil where none may settle enough of them.
    nonisolated static func groundToAdd(
        after report: StyleRecovery.Report,
        index: RegionIndex
    ) async -> (region: Region, codes: Int, size: Int64?)? {
        guard let left = report.remainder else { return nil }
        // Without the list of regions there is nothing to offer: the result stands.
        if index.regions.isEmpty { _ = try? await index.load() }
        guard let best = RegionSuggestion.bestGround(after: report, index: index), left.isWorth(best.codes)
        else { return nil }
        return (best.region, best.codes, await RegionSuggestion.size(of: best.region))
    }

    /// Asks about the regions a refused run needs, each with its size.
    func present(_ picks: [(region: Region, size: Int64?)]) {
        let several = picks.count > 1
        ask(
            title: several ? tn("Download %d region(s)?", picks.count) : t("Download a region?"),
            body: [
                t(
                    "Recovering a style needs OSM data for at least a quarter of the map's area."
                        + " This computer has less."
                ),
                several
                    ? t("The regions offered cover the largest part of the map.")
                    : t("The region offered covers the largest part of the map.")
            ],
            picks
        )
    }

    /// Asks about 1 more region after a run that went through: `codes` is how many of the
    /// codes it left unsettled the region may settle.
    func present(_ region: Region, size: Int64?, settling codes: Int, of left: StyleRecovery.Remainder) {
        ask(
            title: t("Download 1 more region?"),
            body: [
                t(
                    "The meaning of %1$d of the map's %2$d codes is not determined: the data read"
                        + " has too few of them or none. This region may determine %3$d of them. After"
                        + " the download the map is read again.",
                    left.unsettled,
                    left.codes,
                    codes
                )
            ],
            [(region, size)]
        )
    }

    private func ask(title: String, body: [String], _ picks: [(region: Region, size: Int64?)]) {
        offering = Question(
            dialog: Dialog(
                title: title,
                body: body + [
                    picks.count > 1
                        ? t("The files are kept in the cache and used when building maps.")
                        : t("The file is kept in the cache and used when building maps.")
                ],
                detail: picks.map { ($0.region.name, $0.size.map { "≈ \(Fmt.bytes($0))" } ?? "…") },
                confirm: t("download"),
                cancel: t("not now"),
                tone: .plain
            ),
            subject: picks.map(\.region)
        )
    }

    /// Fetches into the cache a build reads, then restarts the run.
    func download(_ regions: [Region], _ ctx: AppContext) {
        phase = .downloading
        startedAt = Date()
        let log = self.log
        let downloader = Downloader(log: log)
        self.downloader = downloader
        // The build's count: a download one stops, the other resumes from the same parts.
        let connections = ctx.settings.settings.downloadConnections

        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await RegionSuggestion.fetch(
                    regions,
                    downloader: downloader,
                    connections: connections
                ) { region in
                    await MainActor.run { self.fetching = region.name }
                }
                guard fetched else { return await MainActor.run { self.stopped() } }
                await MainActor.run { self.start(ctx) }
            } catch is CancellationError {
                await MainActor.run { self.stopped() }
            } catch {
                await MainActor.run {
                    if self.work?.isCancelled == true {
                        self.stopped()
                    } else {
                        self.fail(error)
                    }
                }
            }
        }
    }
}
