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

    /// The download size of every candidate, probed concurrently: extract size does not
    /// follow area, so the choice is made on bytes.
    static func weighed(_ regions: [Candidate]) async -> [(Candidate, Int64)] {
        await withTaskGroup(of: (Candidate, Int64)?.self) { group in
            for candidate in regions {
                group.addTask {
                    guard let url = candidate.region.pbfURL, let info = try? await Downloader.probe(url) else {
                        return nil
                    }
                    return (candidate, info.size)
                }
            }
            var out: [(Candidate, Int64)] = []
            for await answer in group {
                if let answer { out.append(answer) }
            }
            return out
        }
    }
}
