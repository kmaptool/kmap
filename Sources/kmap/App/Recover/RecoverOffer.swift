import Foundation

/// The download offer: which region would cover the map, what it weighs, and fetching
/// it into the cache a build reads.
extension RecoverScreen {
    private static let mostAlternatives = 2
    private static let downloadConnections = 4

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
                let regions = RegionSuggestion.suggestedRegions(on: drawn, index: index)
                guard !regions.isEmpty else {
                    await MainActor.run {
                        self.failure = t("no region kmap can download overlaps this map (%@)", frame.display)
                        self.phase = .failed
                    }
                    return
                }
                let weighed = await Self.weighed(regions)
                guard let pick = RegionSuggestion.worthDownloading(weighed) ?? regions.first else { return }
                await MainActor.run { self.present(pick, among: weighed) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    /// The download size of every candidate, probed concurrently: extract size does not
    /// follow area, so the choice is made on bytes.
    private static func weighed(_ regions: [RegionSuggestion.Candidate]) async -> [(RegionSuggestion.Candidate, Int64)]
    {
        await withTaskGroup(of: (RegionSuggestion.Candidate, Int64)?.self) { group in
            for candidate in regions {
                group.addTask {
                    guard let url = candidate.region.pbfURL, let info = try? await Downloader.probe(url) else {
                        return nil
                    }
                    return (candidate, info.size)
                }
            }
            var out: [(RegionSuggestion.Candidate, Int64)] = []
            for await answer in group {
                if let answer { out.append(answer) }
            }
            return out
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

        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for region in regions {
                    guard let url = region.pbfURL else { continue }
                    await MainActor.run { self.fetching = region.name }
                    try await downloader.download(
                        url: url,
                        to: RegionSuggestion.cacheDestination(for: region),
                        connections: Self.downloadConnections
                    )
                }
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
