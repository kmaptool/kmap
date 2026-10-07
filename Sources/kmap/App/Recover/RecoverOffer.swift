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
                let weighed = await Self.weighed(regions)
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
        // The build's count: a download one stops, the other resumes from the same parts.
        let connections = ctx.settings.settings.downloadConnections

        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // As a build does: no cache clear starts under it.
            Paths.ensure(Paths.locks)
            guard let inUse = await HeldLock.waiting(for: CacheClearing.inUseLock(elevation: false), shared: true)
            else { return await MainActor.run { self.phase = .cancelled } }
            defer { withExtendedLifetime(inUse) {} }
            do {
                for region in regions {
                    guard let latest = region.pbfURL else { continue }
                    await MainActor.run { self.fetching = region.name }
                    // Under the build's lock, landed beside the cache and moved in whole.
                    let destination = RegionSuggestion.cacheDestination(for: region)
                    let landing = BuildPipeline.extractLanding(of: destination)
                    let lock = try await downloader.holdingDownload(of: landing)
                    defer { withExtendedLifetime(lock) {} }
                    // Another kmap may have put it there while this one waited.
                    if FileTools.exists(destination) { continue }
                    // The dated file where the mirror's `-latest` alias is broken.
                    let found = try? await ExtractLocator.locate(latest)
                    let sum = found.map { $0.md5 } ?? region.md5URL
                    var expected: String?
                    if let sum { expected = await Downloader.fetchExpectedMD5(sum) }
                    // A run stopped while it checked a whole download: checked again, not
                    // fetched again.
                    var whole = false
                    if FileTools.exists(landing), !PartFiles(destination: landing).hasParts, let expected {
                        whole = try Downloader.md5(of: landing, shouldStop: { Task.isCancelled }) == expected
                    }
                    if !whole {
                        try await downloader.download(
                            url: found?.url ?? latest,
                            to: landing,
                            connections: connections,
                            lockHeld: true
                        )
                    }
                    // Checked and stamped as a build does, so the next build takes it as is.
                    var md5: String?
                    if let expected {
                        let got = whole ? expected : try Downloader.md5(of: landing, shouldStop: { Task.isCancelled })
                        guard got == expected else {
                            FileTools.removeIfPresent(landing)
                            throw DownloadError.checksumMismatch(expected: expected, got: got)
                        }
                        md5 = got
                    }
                    // Under the lock a copy put back by a build takes too; such a copy gives way.
                    try BuildPipeline.holdingSuspect(of: destination) {
                        FileTools.removeIfPresent(destination)
                        CacheStamp.remove(besides: destination)
                        try FileTools.move(landing, to: destination)
                        CacheStamp(
                            size: FileTools.size(of: destination),
                            lastModified: found?.info.lastModified,
                            md5: md5
                        ).write(besides: destination)
                    }
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
