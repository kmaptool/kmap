import Foundation

/// Stage 2: fetches the OSM extract for each region. Geofabrik publishes a checksum
/// beside every extract; a cached copy is verified against it rather than trusted, since a
/// half-finished download is indistinguishable from a complete one on disk.
extension BuildPipeline {
    // MARK: 2 — download

    /// Maps one region's own 0...1 progress into its slice of the whole download bar,
    /// which advances monotonically across all regions of a build.
    static func overallFraction(region index: Int, of total: Int, at f: Double) -> Double {
        (Double(index) + min(1, max(0, f))) / Double(max(1, total))
    }

    /// Fetches every region going into this map, in order. The stage's closing line says
    /// what actually happened — how many were fetched and how many the cache already
    /// held — because "3 extracts" alone reads the same whether the night was spent
    /// downloading or nothing moved at all.
    func downloadExtracts() async throws -> [URL] {
        var out: [URL] = []
        var fetched = 0
        for (index, region) in recipe.regions.enumerated() {
            if recipe.regions.count > 1 {
                log.step("region \(index + 1) of \(recipe.regions.count): \(region.name)")
            }
            let (url, fresh) = try await downloadExtract(for: region,
                                                         index: index, of: recipe.regions.count)
            if fresh { fetched += 1 }
            out.append(url)
        }
        let cached = out.count - fetched
        set(.download, .done, recipe.regions.count > 1
            ? "\(out.count) extract(s) — " + (fetched == 0 ? "all from the cache"
                : cached == 0 ? "all downloaded"
                : "\(fetched) downloaded, \(cached) from the cache")
            : (fetched == 0 ? "cached · " : "downloaded · ")
                + Fmt.bytes(FileTools.size(of: out[0])))
        return out
    }

    private func downloadExtract(for region: Region, index: Int = 0,
                                 of total: Int = 1) async throws -> (URL, fresh: Bool) {
        guard let pbfURL = region.pbfURL else {
            throw BuildError.notDownloadable(region.name)
        }
        func part(_ f: Double) -> Double { Self.overallFraction(region: index, of: total, at: f) }
        set(.download, .running, t("starting"))

        let destination = Paths.pbfCache
            .appendingPathComponent("\(FileTools.slugify(region.id)).osm.pbf")
        let expected = region.md5URL.map { url in Task { await Downloader.fetchExpectedMD5(url) } }

        var remote: Downloader.RemoteInfo?
        if let cached = try await reusableCachedExtract(at: destination, from: pbfURL,
                                                        expected: expected,
                                                        remote: &remote, part: part) {
            return (cached, fresh: false)
        }

        try Task.checkCancellation()
        return (try await fetchFreshExtract(from: pbfURL, to: destination, expected: expected,
                                            remote: &remote, index: index, of: total),
                fresh: true)
    }

    /// The cached copy, when the server still publishes exactly it. One HEAD request
    /// settles the common case; the checksum settles the rest. A copy the server no
    /// longer offers is removed here, and nil says a fresh download is needed.
    private func reusableCachedExtract(at destination: URL, from pbfURL: URL,
                                       expected: Task<String?, Never>?,
                                       remote: inout Downloader.RemoteInfo?,
                                       part: (Double) -> Double) async throws -> URL? {
        guard FileTools.exists(destination) else { return nil }
        set(.download, .running, t("checking for a newer extract"))
        remote = try? await Downloader.probe(pbfURL)

        // One HEAD request, rather than reading a gigabyte, to ask whether the server
        // still offers what was cached.
        if let remote, let stamp = CacheStamp.read(besides: destination),
           FileTools.size(of: destination) == stamp.size,
           stamp.matches(size: remote.size, lastModified: remote.lastModified) {
            log.ok("cached extract is current (\(Fmt.bytes(stamp.size)))")
            set(.download, .running, "cached · \(Fmt.bytes(stamp.size))", fraction: part(1))
            return destination
        }

        // The server offers something different, or there was nothing to compare
        // against: the checksum settles it.
        if let remoteMD5 = await expected?.value {
            beginPhase(.download, "verifying cached copy")
            log.step("found a cached extract — verifying it")
            // Reported in the text rather than on the bar: verifying is separate work
            // from downloading, and both on one bar leaves it full during the fetch.
            let localMD5 = try Downloader.md5(of: destination) { fraction in
                self.detail(.download,
                            "verifying cached copy · \(Fmt.percent(fraction))")
            }
            if localMD5 == remoteMD5 {
                let size = FileTools.size(of: destination)
                log.ok("cached extract is current (\(Fmt.bytes(size)))")
                CacheStamp(size: size, lastModified: remote?.lastModified,
                           md5: localMD5).write(besides: destination)
                set(.download, .running, "cached · \(Fmt.bytes(size))", fraction: part(1))
                return destination
            }
            // A mismatch says the bytes are not the published ones, not why.
            log.append("the cached extract is not what the server publishes"
                       + " — fetching it again")
            FileTools.removeIfPresent(destination)
            CacheStamp.remove(besides: destination)
        } else if remote == nil {
            // The server is unreachable, so downloading would fail too; the cached
            // extract is used and its possible staleness reported.
            let size = FileTools.size(of: destination)
            log.warn("could not reach the server — building from the cached extract"
                     + " (\(Fmt.bytes(size))), which may be out of date")
            set(.download, .running, "cached · \(Fmt.bytes(size))", fraction: part(1))
            return destination
        } else {
            log.append("no checksum published and the server is offering something"
                       + " different — downloading a fresh copy")
            FileTools.removeIfPresent(destination)
            CacheStamp.remove(besides: destination)
        }
        return nil
    }

    /// Downloads the extract and verifies the bytes just fetched against the published
    /// checksum, stamping the cache either way.
    private func fetchFreshExtract(from pbfURL: URL, to destination: URL,
                                   expected: Task<String?, Never>?,
                                   remote: inout Downloader.RemoteInfo?,
                                   index: Int, of total: Int) async throws -> URL {
        log.step("downloading \(pbfURL.lastPathComponent)")
        // The bar restarts from this region's beginning rather than where the check for a
        // cached copy left it.
        beginPhase(.download, "starting")

        let downloader = Downloader(log: log)
        retain(downloader)

        // Mirrors the downloader's own progress into this stage.
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = downloader.progress
                let text = "\(Fmt.bytes(p.received)) / \(Fmt.bytes(p.total))"
                    + "  ·  \(Fmt.rate(p.rate))"
                    + (p.eta.isFinite ? "  ·  \(Fmt.duration(p.eta)) left" : "")
                self.detail(.download, text, fraction: Self.overallFraction(
                    region: index, of: total, at: p.fraction))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { monitor.cancel() }

        try await downloader.download(url: pbfURL, to: destination,
                                      connections: recipe.downloadConnections)

        if let expectedTask = expected, let remoteMD5 = await expectedTask.value {
            beginPhase(.download, "verifying checksum")
            let localMD5 = try Downloader.md5(of: destination) { fraction in
                self.detail(.download, "verifying checksum · \(Fmt.percent(fraction))")
            }
            guard localMD5 == remoteMD5 else {
                FileTools.removeIfPresent(destination)
                throw DownloadError.checksumMismatch(expected: remoteMD5, got: localMD5)
            }
            log.ok("checksum verified")
            CacheStamp(size: FileTools.size(of: destination),
                       lastModified: remote?.lastModified, md5: remoteMD5)
                .write(besides: destination)
        } else {
            log.warn("no .md5 published for this extract — skipping checksum verification")
            // Stamped anyway, or the next build cannot tell whether the server has moved
            // on and refetches the whole extract.
            if remote == nil { remote = try? await Downloader.probe(pbfURL) }
            CacheStamp(size: FileTools.size(of: destination),
                       lastModified: remote?.lastModified, md5: nil)
                .write(besides: destination)
        }

        let size = FileTools.size(of: destination)
        log.ok("downloaded \(Fmt.bytes(size))")
        set(.download, .done, Fmt.bytes(size))
        return destination
    }
}
