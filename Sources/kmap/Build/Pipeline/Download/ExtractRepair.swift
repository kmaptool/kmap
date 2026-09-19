import Foundation

/// A cached extract that went bad on disk. The stamp lets a build trust a cached copy
/// without reading it, so damage that keeps the size shows up only when the extract will
/// not decode. The build then checks its extracts against the checksums they were
/// downloaded with, fetches the damaged ones again and carries on, once.
extension BuildPipeline {
    /// Whether a failure reads like an extract that would not decode, rather than anything
    /// the build itself did.
    static func readsLikeADamagedExtract(_ error: Error) -> Bool {
        error is PBFError || error is Zlib.Failure
    }

    /// The extracts whose bytes are no longer the ones that were downloaded. One without a
    /// recorded checksum cannot be told either way and counts as damaged: fetching it again
    /// is the only check there is.
    func damagedExtracts(among extracts: [URL]) -> [URL] {
        extracts.filter { extract in
            guard let recorded = CacheStamp.read(besides: extract)?.md5 else { return true }
            let what = t("verifying cached copy")
            let found = try? Downloader.md5(of: extract) { fraction in
                self.detail(.download, what + " · " + Fmt.percent(fraction))
            }
            return found != recorded
        }
    }

    /// Fetches the damaged extracts again. The stages that were running go back to
    /// pending, or they keep their spinners beside the download.
    ///
    /// - Returns: The extracts to build from, or nil where none of them was damaged and
    ///   the failure is somebody else's.
    func refetchDamagedExtracts(among extracts: [URL]) async throws -> [URL]? {
        let closingLine = board.detail(of: .download)
        set(.download, .running, t("verifying cached copy"))
        let damaged = damagedExtracts(among: extracts)
        guard !damaged.isEmpty else {
            set(.download, .done, closingLine)
            return nil
        }
        for extract in damaged {
            log.warn(
                "the downloaded map data in \(extract.lastPathComponent) was damaged on"
                    + " disk — downloading it again"
            )
            FileTools.removeIfPresent(extract)
            CacheStamp.remove(besides: extract)
        }
        for id in board.running where id != .download { set(id, .pending, "") }
        set(.download, .running, t("cached copy was damaged — downloading again"))
        return try await downloadExtracts()
    }
}
