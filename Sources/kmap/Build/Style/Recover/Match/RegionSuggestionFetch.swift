import Foundation

/// Fetching the extracts a recovery reads into the cache a build reads.
extension RegionSuggestion {
    /// Downloads each region not cached yet, checked and stamped as a build does.
    ///
    /// - Parameter starting: told each region as its download starts.
    /// - Returns: false where the wait for the cache was cancelled.
    static func fetch(
        _ regions: [Region],
        downloader: Downloader,
        connections: Int,
        starting: (Region) async -> Void = { _ in }
    ) async throws -> Bool {
        // As a build does: no cache clear starts under it.
        Paths.ensure(Paths.locks)
        guard let inUse = await HeldLock.waiting(for: CacheClearing.inUseLock(elevation: false), shared: true)
        else { return false }
        defer { withExtendedLifetime(inUse) {} }
        for region in regions {
            guard let latest = region.pbfURL else { continue }
            await starting(region)
            // Under the build's lock, landed beside the cache and moved in whole.
            let destination = cacheDestination(for: region)
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
            // A run stopped while it checked a whole download: checked again, not fetched again.
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
        return true
    }

    /// The regions recover fetches next, each with its size where the server says:
    /// `groundToFetch`. With `asking` and none of those, the first of `groundToName` not in
    /// the cache: a region to ask about, not one to fetch unasked. `reached` is whether
    /// any region holds any of the map at all.
    static func nextGround(
        for img: URL,
        index: RegionIndex,
        asking: Bool
    ) async -> (picks: [(region: Region, size: Int64?)], reached: Bool) {
        let drawn = drawnGround(of: img)
        let named = groundToName(for: drawn, index: index)
        var regions = groundToFetch(for: drawn, index: index).map(\.region)
        // A cached one was read already: picked again, it would be offered in a loop.
        if regions.isEmpty, asking, let other = named.first(where: { !isCached($0.region) }) {
            regions = [other.region]
        }
        var picks: [(region: Region, size: Int64?)] = []
        for region in regions { picks.append((region, await size(of: region))) }
        return (picks, !named.isEmpty)
    }

    /// After a run: among the regions that are ground to read and not in the cache, the
    /// one that may settle the most of the codes the run left unsettled, and how many.
    /// Nil where none may settle any.
    static func bestGround(after report: StyleRecovery.Report, index: RegionIndex) -> (region: Region, codes: Int)? {
        guard let left = report.remainder, !left.drawn.isEmpty, let drawn = report.drawn else { return nil }
        let candidates = groundToRead(for: drawn, index: index).map(\.region).filter { !isCached($0) }
        return left.bestRegion(among: Set(candidates.map(\.id)), owners: owners(in: index))
    }

    /// The size of a region's extract, where the server says.
    static func size(of region: Region) async -> Int64? {
        guard let url = region.pbfURL else { return nil }
        return try? await Downloader.probe(url).size
    }
}
