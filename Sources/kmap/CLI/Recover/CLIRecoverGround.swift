import Foundation

/// The OSM ground `kmap recover` reads when no extract is named and the cached extracts
/// fall short: regions downloaded 1 at a time into the cache a build reads.
extension CLI {
    /// Downloads the regions holding the most of the map's data among those not cached
    /// yet, as many as give a run ground enough. False where no region that is ground to
    /// read is left.
    static func downloadRegion(for img: URL, log: Log) async throws -> Bool {
        let index = RegionIndex()
        try await index.load()
        let next = await RegionSuggestion.nextGround(for: img, index: index, asking: false)
        for pick in next.picks {
            // Said before it starts: an extract can take minutes, and the log prints after.
            let size = pick.size.map { ", \(Fmt.bytes($0))" } ?? ""
            CLILog.line("downloading \(pick.region.id)\(size), the ground recover reads")
            try await fetch(pick.region, log: log)
        }
        return !next.picks.isEmpty
    }

    /// After a run that went through, without --more: the region that may settle enough of
    /// the codes it left unsettled to be worth reading, by the index kept on this machine.
    /// Nil where there is none.
    static func groundWorthReading(after report: StyleRecovery.Report) -> (region: Region, codes: Int)? {
        guard let left = report.remainder, let index = RegionIndex.kept(),
            let best = RegionSuggestion.bestGround(after: report, index: index), left.isWorth(best.codes)
        else { return nil }
        return best
    }

    /// Names that region and the flag that reads it, with its size where the server says.
    static func adviseMore(_ best: (region: Region, codes: Int)) async {
        let size = await RegionSuggestion.size(of: best.region).map { ", \(Fmt.bytes($0))" } ?? ""
        CLILog.line(
            "\n\(best.region.id) may settle \(best.codes) of the codes not settled:"
                + " --more downloads it\(size) and reads the map again"
        )
    }

    /// After a run that went through, with --more: downloads the region that may settle
    /// the most of the codes it left unsettled. False where none may settle enough of them
    /// to be worth reading, and why is said.
    static func readMore(after report: StyleRecovery.Report, log: Log) async throws -> Bool {
        guard let left = report.remainder, left.unsettled > 0 else { return false }
        let index = RegionIndex()
        try await index.load()
        guard let best = RegionSuggestion.bestGround(after: report, index: index) else {
            CLILog.line("no region left to download may settle any of the codes not settled")
            return false
        }
        guard left.isWorth(best.codes) else {
            CLILog.line(
                "the region that may settle the most of the codes not settled, \(best.region.id),"
                    + " may settle \(best.codes): too few to read it for"
            )
            return false
        }
        let size = await RegionSuggestion.size(of: best.region).map { ", \(Fmt.bytes($0))" } ?? ""
        CLILog.line(
            "\(best.region.id) may settle \(best.codes) of the codes not settled:"
                + " downloading it\(size) and reading the map again"
        )
        try await fetch(best.region, log: log)
        return true
    }

    private static func fetch(_ region: Region, log: Log) async throws {
        let fetched = try await RegionSuggestion.fetch(
            [region],
            downloader: Downloader(log: log),
            connections: SettingsStore().settings.downloadConnections
        )
        guard fetched else { throw CancellationError() }
    }
}
