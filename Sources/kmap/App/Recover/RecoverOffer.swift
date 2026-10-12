import Foundation

/// The download offer: which region would cover the map, what it weighs, and fetching
/// it into the cache a build reads.
extension RecoverScreen {
    private static let mostAlternatives = 2

    /// Weighs the regions that would cover the map and offers the lightest worth having.
    func offer(_ ctx: AppContext, frame: BBox) {
        let index = ctx.index
        let img = img

        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if index.regions.isEmpty { try await index.load() }
                // Against the map's own tiles, not its frame, which spans ground a
                // non-rectangular map never draws.
                let drawn = RegionSuggestion.drawnGround(of: img)
                let suggested = RegionSuggestion.suggestedRegions(on: drawn, index: index)
                // A cached one was already found off the map: offered again, it would be
                // downloaded and refused in a loop.
                let regions = suggested.filter { !FileTools.exists(RegionSuggestion.cacheDestination(for: $0.region)) }
                guard !regions.isEmpty else {
                    await MainActor.run {
                        self.failure =
                            suggested.isEmpty
                            ? t("no region kmap can download overlaps this map (%@)", frame.display)
                            : t(
                                "the extracts kmap holds around this map do not cover what it draws (%@)",
                                frame.display
                            )
                        self.phase = .failed
                    }
                    return
                }
                let weighed = await RegionSuggestion.weighed(regions)
                guard let pick = RegionSuggestion.worthDownloading(weighed) ?? regions.first else { return }
                // Esc while the sizes were asked: no dialog, and a screen Esc can leave.
                guard !Task.isCancelled else {
                    await MainActor.run { self.phase = .cancelled }
                    return
                }
                await MainActor.run { self.present(pick, among: weighed) }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    /// The pick with its size, and the runners-up standing on the same ground under it.
    private func present(_ pick: RegionSuggestion.Candidate, among weighed: [(RegionSuggestion.Candidate, Int64)]) {
        let size = weighed.first { $0.0.region.id == pick.region.id }?.1
        var detail = [(pick.region.name, size.map { "≈ \(Fmt.bytes($0))" } ?? "…")]
        let alternatives =
            weighed
            .filter { $0.0.region.id != pick.region.id && $0.0.isInside == pick.isInside }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.mostAlternatives)
        for (other, bytes) in alternatives {
            detail.append((other.region.name, "≈ \(Fmt.bytes(bytes))"))
        }

        offering = Question(
            dialog: Dialog(
                title: t("Download a region?"),
                body: [
                    t(
                        "No OSM data on this machine matches this map. Recovering the style"
                            + " does not need the whole map covered — the codes a style uses are"
                            + " used everywhere it draws, so one region inside the map is enough"
                            + " to read them."
                    ),
                    t(
                        "The first is what kmap would take; it lands in the same cache a"
                            + " build reads, so the next build has it too."
                    )
                ],
                detail: detail,
                confirm: t("download"),
                cancel: t("not now"),
                tone: .plain
            ),
            subject: [pick.region]
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
                guard fetched else { return await MainActor.run { self.phase = .cancelled } }
                await MainActor.run { self.start(ctx) }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                await MainActor.run {
                    if self.work?.isCancelled == true {
                        self.phase = .cancelled
                    } else {
                        self.fail(error)
                    }
                }
            }
        }
    }
}
