import Foundation

/// Stage 2: fetches the OSM extract for each region. Geofabrik publishes a checksum
/// beside every extract; a cached copy is verified against it rather than trusted, since a
/// half-finished download is indistinguishable from a complete one on disk.
///
/// The stage has one bar for all its regions. It stays `.running` and its fraction is
/// never cleared between them, or the bar would start over for each; verifying is
/// reported in the text only, since it is separate work from downloading.
extension BuildPipeline {
    // MARK: 2 - download

    /// One region's place in the stage.
    private struct ExtractJob {
        let region: Region
        let source: URL
        let destination: URL
        /// "2/3" and a separator where there are several regions, empty for one: the byte
        /// counts beside it belong to this region alone.
        let label: String
        /// The region's own 0...1 progress as a position on the stage's bar.
        let part: (Double) -> Double
        /// Bytes still to be fetched after this region, for the time left.
        let bytesAfter: Int64
        /// The published checksum, asked for as the job begins.
        let expected: Task<String?, Never>?
        /// What the server says about the extract; nil until asked, or unreachable.
        var remote: Downloader.RemoteInfo?
    }

    /// Fetches every region going into this map, in order. The closing line says how many
    /// were fetched and how many the cache already held: "3 extracts" alone reads the
    /// same whether the night was spent downloading or nothing moved at all.
    func downloadExtracts() async throws -> [URL] {
        let regions = recipe.regions
        let probes = await probeExtracts()
        let cached = regions.map { Paths.cachedExtract(forRegion: $0.id) }
        // The server's size, or the cached copy's where the server did not answer.
        let sizes = regions.indices.map { probes[$0]?.size ?? FileTools.size(of: cached[$0]) }
        let slices = DownloadSlices(sizes: sizes)
        // What each region will cost to fetch: nothing where the cached copy is current.
        let toFetch = regions.indices.map {
            cachedCopyIsCurrent(at: cached[$0], remote: probes[$0]) ? 0 : sizes[$0]
        }

        var out: [URL] = []
        var fetched = 0
        for (index, region) in regions.enumerated() {
            // A cached region needs no network and would otherwise run past a cancel.
            try stopIfCancelled()
            guard let source = region.pbfURL else {
                throw BuildError.notDownloadable(region.name)
            }
            if regions.count > 1 {
                log.step("region \(index + 1) of \(regions.count): \(region.name)")
            }
            var job = ExtractJob(
                region: region, source: source, destination: cached[index],
                label: regions.count > 1
                    ? "\(index + 1)/\(regions.count)" + DownloadProgress.separator : "",
                part: { slices.fraction(region: index, at: $0) },
                bytesAfter: toFetch[(index + 1)...].reduce(0, +),
                expected: region.md5URL.map { url in
                    Task { await Downloader.fetchExpectedMD5(url) }
                },
                remote: probes[index])
            if try await !reuseCachedExtract(&job) {
                try Task.checkCancellation()
                try await fetchFreshExtract(&job)
                fetched += 1
            }
            out.append(job.destination)
        }
        set(.download, .done, summary(of: out, fetched: fetched))
        return out
    }

    /// The stage's closing line.
    private func summary(of extracts: [URL], fetched: Int) -> String {
        guard extracts.count > 1 else {
            return (fetched == 0 ? t("cached") : t("downloaded")) + " · "
                + Fmt.bytes(FileTools.size(of: extracts[0]))
        }
        let cached = extracts.count - fetched
        let how = fetched == 0 ? t("all from the cache")
            : cached == 0 ? t("all downloaded")
            : t("%1$d downloaded, %2$d from the cache", fetched, cached)
        return tn("%d extract(s)", extracts.count) + " — " + how
    }

    /// One HEAD request per region, all at once. Each answer sizes the region's slice of
    /// the bar and is handed on to the check of its cached copy, which would otherwise ask
    /// again. A build of one region has nothing to apportion and asks later.
    private func probeExtracts() async -> [Downloader.RemoteInfo?] {
        let regions = recipe.regions
        var answers = [Downloader.RemoteInfo?](repeating: nil, count: regions.count)
        guard regions.count > 1 else { return answers }
        set(.download, .running, t("checking for a newer extract"))
        await withTaskGroup(of: (Int, Downloader.RemoteInfo?).self) { group in
            for (index, region) in regions.enumerated() {
                guard let url = region.pbfURL else { continue }
                group.addTask { (index, try? await Downloader.probe(url)) }
            }
            for await (index, answer) in group { answers[index] = answer }
        }
        return answers
    }

    // MARK: The cached copy

    /// Whether the stamp beside a cached copy says the server still offers exactly it:
    /// one HEAD request, rather than reading a gigabyte.
    private func cachedCopyIsCurrent(at destination: URL, remote: Downloader.RemoteInfo?) -> Bool {
        guard let remote, let stamp = CacheStamp.read(besides: destination) else { return false }
        return FileTools.size(of: destination) == stamp.size
            && stamp.matches(size: remote.size, lastModified: remote.lastModified)
    }

    /// Reports the region as served from the cache, filling its slice of the bar.
    private func settleOnCachedCopy(_ job: ExtractJob) {
        let size = Fmt.bytes(FileTools.size(of: job.destination))
        set(.download, .running, t("cached") + " · " + size, fraction: job.part(1))
    }

    private func discardCachedCopy(_ job: ExtractJob) {
        FileTools.removeIfPresent(job.destination)
        CacheStamp.remove(besides: job.destination)
    }

    /// Whether the cached copy serves: the server still publishes exactly it. The stamp
    /// settles the common case and the checksum the rest. A copy the server no longer
    /// offers is removed here, and false says a fresh download is needed.
    private func reuseCachedExtract(_ job: inout ExtractJob) async throws -> Bool {
        set(.download, .running, t("starting"))
        guard FileTools.exists(job.destination) else { return false }
        set(.download, .running, t("checking for a newer extract"))
        if job.remote == nil { job.remote = try? await Downloader.probe(job.source) }

        if cachedCopyIsCurrent(at: job.destination, remote: job.remote) {
            log.ok("cached extract is current (\(Fmt.bytes(FileTools.size(of: job.destination))))")
            settleOnCachedCopy(job)
            return true
        }

        // The server offers something different, or there was nothing to compare against.
        guard let remoteMD5 = await job.expected?.value else {
            if job.remote == nil {
                // Unreachable, so downloading would fail too: the cached extract is used
                // and its possible staleness reported.
                log.warn("could not reach the server — building from the cached extract ("
                         + Fmt.bytes(FileTools.size(of: job.destination))
                         + "), which may be out of date")
                settleOnCachedCopy(job)
                return true
            }
            log.append("no checksum published and the server is offering something"
                       + " different — downloading a fresh copy")
            discardCachedCopy(job)
            return false
        }

        // The checksum recorded at download already differs from the published one: the
        // copy is stale, and reading it end to end would only say so again.
        if CacheStamp.read(besides: job.destination)?.isSuperseded(by: remoteMD5) == true {
            log.append("the server publishes a newer extract — fetching it")
            discardCachedCopy(job)
            return false
        }

        log.step("found a cached extract — verifying it")
        let localMD5 = try checksum(of: job, saying: t("verifying cached copy"))
        guard localMD5 == remoteMD5 else {
            // A mismatch says the bytes are not the published ones, not why.
            log.append("the cached extract is not what the server publishes — fetching it again")
            discardCachedCopy(job)
            return false
        }
        log.ok("cached extract is current (\(Fmt.bytes(FileTools.size(of: job.destination))))")
        stamp(job, md5: localMD5)
        settleOnCachedCopy(job)
        return true
    }

    // MARK: A fresh copy

    /// Downloads the extract and verifies the bytes just fetched against the published
    /// checksum, stamping the cache either way.
    private func fetchFreshExtract(_ job: inout ExtractJob) async throws {
        log.step("downloading \(job.source.lastPathComponent)")
        let downloader = Downloader(log: log)
        retain(downloader)

        // Mirrors the downloader's own progress into this stage. The time left is the
        // stage's, like the bar it stands beside.
        let monitor = Task { [weak self, job] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = downloader.progress
                let left = Self.stageSecondsLeft(fileSecondsLeft: p.eta, rate: p.rate,
                                                 bytesAfterThisFile: job.bytesAfter)
                self.detail(.download, job.label + p.line(secondsLeft: left),
                            fraction: job.part(p.fraction))
                try? await Task.sleep(nanoseconds: BuildPipeline.progressTick)
            }
        }
        defer { monitor.cancel() }

        try await downloader.download(url: job.source, to: job.destination,
                                      connections: recipe.downloadConnections)

        if let remoteMD5 = await job.expected?.value {
            let localMD5 = try checksum(of: job, saying: job.label + t("verifying checksum"))
            guard localMD5 == remoteMD5 else {
                FileTools.removeIfPresent(job.destination)
                throw DownloadError.checksumMismatch(expected: remoteMD5, got: localMD5)
            }
            log.ok("checksum verified")
            stamp(job, md5: remoteMD5)
        } else {
            log.warn("no .md5 published for this extract — skipping checksum verification")
            // Stamped anyway, or the next build cannot tell whether the server has moved
            // on and refetches the whole extract.
            if job.remote == nil { job.remote = try? await Downloader.probe(job.source) }
            stamp(job, md5: nil)
        }
        log.ok("downloaded \(Fmt.bytes(FileTools.size(of: job.destination)))")
    }

    // MARK: Shared

    /// The MD5 of the job's file, its progress reported in the stage's text.
    private func checksum(of job: ExtractJob, saying what: String) throws -> String {
        detail(.download, what)
        return try Downloader.md5(of: job.destination) { fraction in
            self.detail(.download, what + " · " + Fmt.percent(fraction))
        }
    }

    /// Records what the server said about the file now on disk.
    private func stamp(_ job: ExtractJob, md5: String?) {
        CacheStamp(size: FileTools.size(of: job.destination),
                   lastModified: job.remote?.lastModified, md5: md5)
            .write(besides: job.destination)
    }
}
