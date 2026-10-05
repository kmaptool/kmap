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
        /// The mirror's `-latest` file, or a dated one standing in for it.
        var source: URL
        let destination: URL
        /// "2/3" and a separator where there are several regions, empty for one: the byte
        /// counts beside it belong to this region alone.
        let label: String
        /// The region's own 0...1 progress as a position on the stage's bar.
        let part: @Sendable (Double) -> Double
        /// Bytes still to be fetched after this region, for the time left.
        let bytesAfter: Int64
        /// The published checksum, asked for as the job begins, and where it is published.
        var expected: Task<String?, Never>?
        var checksumURL: URL?
        /// What the server says about the extract; nil until asked, or unreachable.
        var remote: Downloader.RemoteInfo?
        /// Why the last probe failed, for the warning that falls back to the cache.
        var unreachable: String?
    }

    /// Fetches every region going into this map, in order. The closing line says how many
    /// were fetched and how many the cache already held: "3 extracts" alone reads the
    /// same whether the night was spent downloading or nothing moved at all.
    func downloadExtracts() async throws -> [URL] {
        let regions = recipe.regions
        let probes = await probeExtracts()
        let cached = regions.map { Paths.cachedExtract(forRegion: $0.id) }
        // The server's size, or the cached copy's where the server did not answer.
        let sizes = regions.indices.map { probes[$0].source?.info.size ?? FileTools.size(of: cached[$0]) }
        let slices = DownloadSlices(sizes: sizes)
        // What each region will cost to fetch: nothing where the cached copy is current.
        let toFetch = regions.indices.map {
            let remote = probes[$0].source?.info
            return cachedCopyIsCurrent(at: cached[$0], remote: remote)
                || cachedCopyIsNewer(at: cached[$0], remote: remote) != nil ? 0 : sizes[$0]
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
                region: region,
                source: source,
                destination: cached[index],
                label: regions.count > 1
                    ? "\(index + 1)/\(regions.count)" + DownloadProgress.separator : "",
                part: { slices.fraction(region: index, at: $0) },
                bytesAfter: toFetch[(index + 1)...].reduce(0, +),
                expected: nil
            )
            // Asked here where the shared probe did not: a build of one region. The
            // answer names the file to take, which need not be the `-latest` one.
            if probes[index].source == nil, probes[index].refused == nil {
                set(.download, .running, t("checking for a newer extract"))
                adopt(await Self.probeOnce(source), into: &job)
            } else {
                adopt(probes[index], into: &job)
            }
            if try await !reuseCachedExtract(&job) {
                try Task.checkCancellation()
                do {
                    if try await fetchFreshExtract(&job) { fetched += 1 }
                } catch {
                    try rethrowIfCancelled(error)
                    // The older copy was kept for exactly this: a mirror that answers
                    // the question and then fails the download.
                    guard FileTools.exists(job.destination) else { throw error }
                    log.warn(
                        "the download did not get through (\(error.localizedDescription))"
                            + " — building from the cached extract ("
                            + Fmt.bytes(FileTools.size(of: job.destination)) + "), which is out of date"
                    )
                    settleOnCachedCopy(job)
                }
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
        let how =
            fetched == 0
            ? t("all from the cache")
            : cached == 0
                ? t("all downloaded")
                : t("%1$d downloaded, %2$d from the cache", fetched, cached)
        return tn("%d extract(s)", extracts.count) + " — " + how
    }

    /// An answer, or why there is none. The reason is kept so a region is not asked
    /// again, with the same retries, after the answer is already no.
    private typealias Probe = (source: ExtractSource?, refused: String?)

    /// One HEAD request per region, all at once. Each answer sizes the region's slice of
    /// the bar and is handed on to the check of its cached copy, which would otherwise ask
    /// again. A build of one region has nothing to apportion and asks later.
    private func probeExtracts() async -> [Probe] {
        let regions = recipe.regions
        // Each answer goes to its own place, not back through the group: see
        // `ExtractLocator.newestAnswering`.
        let answers = Locked([Probe](repeating: (nil, nil), count: regions.count))
        guard regions.count > 1 else { return answers.withLock { $0 } }
        set(.download, .running, t("checking for a newer extract"))
        await withTaskGroup(of: Void.self) { group in
            for (index, region) in regions.enumerated() {
                guard let url = region.pbfURL else { continue }
                group.addTask {
                    let answer = await Self.probeOnce(url)
                    answers.withLock { $0[index] = answer }
                }
            }
        }
        return answers.withLock { $0 }
    }

    /// The retried probe, its failure kept as words rather than thrown.
    private static func probeOnce(_ url: URL) async -> Probe {
        do {
            return (try await ExtractLocator.locate(url), nil)
        } catch {
            // localizedDescription, not the error's dump: "too many HTTP redirects" is the
            // line, the domain and code are not.
            return (nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: The cached copy

    /// Whether the stamp beside a cached copy says the server still offers exactly it:
    /// one HEAD request, rather than reading a gigabyte.
    private func cachedCopyIsCurrent(at destination: URL, remote: Downloader.RemoteInfo?) -> Bool {
        guard let remote, let stamp = CacheStamp.read(besides: destination) else { return false }
        return FileTools.size(of: destination) == stamp.size
            && stamp.matches(size: remote.size, lastModified: remote.lastModified)
    }

    /// The 2 publication dates where the cached copy, whole, is newer than what the server
    /// offers; nil where it is not, or where a date is missing.
    private func cachedCopyIsNewer(
        at destination: URL,
        remote: Downloader.RemoteInfo?
    ) -> (cached: String, offered: String)? {
        guard let stamp = CacheStamp.read(besides: destination),
            FileTools.size(of: destination) == stamp.size,
            stamp.isNewer(thanOffered: remote?.lastModified),
            let cached = stamp.lastModified, let offered = remote?.lastModified
        else { return nil }
        return (cached, offered)
    }

    /// Reports the region as served from the cache, filling its slice of the bar.
    private func settleOnCachedCopy(_ job: ExtractJob) {
        let size = Fmt.bytes(FileTools.size(of: job.destination))
        set(.download, .running, t("cached") + " · " + size, fraction: job.part(1))
    }

    /// Whether the cached copy serves: the server still publishes exactly it. The stamp
    /// settles the common case and the checksum the rest. False says a fresh download is
    /// needed; the older copy stays where it is until that download has landed, so a
    /// mirror that fails halfway leaves something to build from.
    private func reuseCachedExtract(_ job: inout ExtractJob) async throws -> Bool {
        set(.download, .running, t("starting"))
        guard FileTools.exists(job.destination) else { return false }
        set(.download, .running, t("checking for a newer extract"))

        if cachedCopyIsCurrent(at: job.destination, remote: job.remote) {
            log.ok("cached extract is current (\(Fmt.bytes(FileTools.size(of: job.destination))))")
            settleOnCachedCopy(job)
            return true
        }

        if let dates = cachedCopyIsNewer(at: job.destination, remote: job.remote) {
            log.ok(
                "the server offers an extract published \(dates.offered), older than the cached one"
                    + " (\(dates.cached)) — keeping the cached extract"
            )
            settleOnCachedCopy(job)
            return true
        }

        // The server offers something different, or there was nothing to compare against.
        guard let remoteMD5 = await job.expected?.value else {
            if job.remote == nil {
                // Unreachable after the retries, so downloading would fail too: the
                // cached extract is used and its possible staleness reported, with why.
                log.warn(
                    "could not reach the server (\(job.unreachable ?? "no answer"))"
                        + " — building from the cached extract ("
                        + Fmt.bytes(FileTools.size(of: job.destination))
                        + "), which may be out of date"
                )
                settleOnCachedCopy(job)
                return true
            }
            log.append(
                "no checksum to be had and the server is offering something"
                    + " different — downloading a fresh copy"
            )
            return false
        }

        // The checksum recorded at download already differs from the published one: the
        // copy is stale, and reading it end to end would only say so again.
        if CacheStamp.read(besides: job.destination)?.isSuperseded(by: remoteMD5) == true {
            log.append("the server publishes a newer extract — fetching it")
            return false
        }

        log.step("found a cached extract — verifying it")
        let localMD5 = try checksum(of: job.destination, saying: t("verifying cached copy"))
        guard localMD5 == remoteMD5 else {
            // A mismatch says the bytes are not the published ones, not why.
            log.append("the cached extract is not what the server publishes — fetching it again")
            return false
        }
        log.ok("cached extract is current (\(Fmt.bytes(FileTools.size(of: job.destination))))")
        stamp(job, md5: localMD5)
        settleOnCachedCopy(job)
        return true
    }

    // MARK: A fresh copy

    /// Downloads the extract and verifies the bytes just fetched against the published
    /// checksum, stamping the cache either way. False when another kmap fetched it first.
    private func fetchFreshExtract(_ job: inout ExtractJob) async throws -> Bool {
        log.step("downloading \(job.source.lastPathComponent)")
        let downloader = Downloader(log: log)
        retain(downloader)

        // Mirrors the downloader's own progress into this stage. The time left is the
        // stage's, like the bar it stands beside.
        // It holds the board and not the build: the board is what may be shared.
        let (label, part, bytesAfter, board) = (job.label, job.part, job.bytesAfter, board)
        let monitor = Task {
            while !Task.isCancelled {
                let p = downloader.progress
                let left = BuildPipeline.stageSecondsLeft(
                    fileSecondsLeft: p.eta,
                    rate: p.rate,
                    bytesAfterThisFile: bytesAfter
                )
                board.detail(
                    .download,
                    label + p.line(secondsLeft: left),
                    fraction: part(p.fraction)
                )
                try? await Task.sleep(nanoseconds: BuildPipeline.progressTick)
            }
        }
        defer { monitor.cancel() }

        // Beside the cached copy, not over it: the copy is replaced only by a file that
        // arrived whole and matched its checksum.
        let landing = job.destination.appendingPathExtension("new")
        // Held from here to the move into the cache: another kmap fetching the same file
        // would otherwise write a new landing over the one this run is checking.
        let lock = try await downloader.holdingDownload(of: landing)
        defer { withExtendedLifetime(lock) {} }
        // Another run may have put a current copy in place while this one waited.
        if cachedCopyIsCurrent(at: job.destination, remote: job.remote) {
            log.ok("another kmap has just downloaded it")
            settleOnCachedCopy(job)
            return false
        }
        // A run stopped while it checked a whole download leaves it with no parts beside
        // it: checked again, not fetched again.
        var whole = false
        if FileTools.exists(landing), !PartFiles(destination: landing).hasParts,
            let expected = await job.expected?.value
        {
            whole = try checksum(of: landing, saying: job.label + t("verifying checksum")) == expected
        }
        if whole {
            log.append("the file a stopped run downloaded is whole — not fetched again")
        } else {
            try await downloader.download(
                url: job.source,
                to: landing,
                connections: recipe.downloadConnections,
                lockHeld: true
            )
        }

        var remoteMD5 = await job.expected?.value
        // Asked once more: a mirror that hung on the checksum before the download may
        // answer after it, and the file is better verified than not.
        if remoteMD5 == nil, let url = job.checksumURL { remoteMD5 = await Downloader.fetchExpectedMD5(url) }
        if let remoteMD5, !whole {
            let localMD5 = try checksum(of: landing, saying: job.label + t("verifying checksum"))
            guard localMD5 == remoteMD5 else {
                FileTools.removeIfPresent(landing)
                throw DownloadError.checksumMismatch(expected: remoteMD5, got: localMD5)
            }
        }
        FileTools.removeIfPresent(job.destination)
        CacheStamp.remove(besides: job.destination)
        try FileTools.move(landing, to: job.destination)

        if let remoteMD5 {
            log.ok("checksum verified")
            stamp(job, md5: remoteMD5)
        } else {
            log.warn("no .md5 to be had for this extract — skipping checksum verification")
            // Stamped anyway, or the next build cannot tell whether the server has moved
            // on and refetches the whole extract.
            // The download itself just got through, so an earlier refusal is stale.
            if job.remote == nil { adopt(await Self.probeOnce(job.source), into: &job) }
            stamp(job, md5: nil)
        }
        log.ok("downloaded \(Fmt.bytes(FileTools.size(of: job.destination)))")
        return true
    }

    // MARK: Shared

    /// Takes a probe's answer into the job: the file to fetch and its checksum, or the
    /// reason there is none. A dated file standing in for a broken `-latest` is said.
    private func adopt(_ probe: Probe, into job: inout ExtractJob) {
        job.unreachable = probe.refused
        guard let found = probe.source else {
            if job.expected == nil, let md5 = job.region.md5URL {
                job.checksumURL = md5
                job.expected = Task { await Downloader.fetchExpectedMD5(md5) }
            }
            return
        }
        job.remote = found.info
        if let standIn = found.standIn, found.url != job.source {
            log.warn(
                "the mirror is not serving \(job.source.lastPathComponent) — taking \(standIn),"
                    + " the newest that answers"
            )
        }
        job.source = found.url
        job.checksumURL = found.md5
        job.expected = found.md5.map { url in Task { await Downloader.fetchExpectedMD5(url) } }
    }

    /// The MD5 of the job's file, its progress reported in the stage's text.
    private func checksum(of file: URL, saying what: String) throws -> String {
        detail(.download, what)
        return try Downloader.md5(of: file, shouldStop: stopAsked) { fraction in
            self.detail(.download, what + " · " + Fmt.percent(fraction))
        }
    }

    /// Records what the server said about the file now on disk.
    private func stamp(_ job: ExtractJob, md5: String?) {
        CacheStamp(
            size: FileTools.size(of: job.destination),
            lastModified: job.remote?.lastModified,
            md5: md5
        )
        .write(besides: job.destination)
    }
}
