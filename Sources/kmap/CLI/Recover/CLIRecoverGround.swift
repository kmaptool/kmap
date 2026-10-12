import Foundation

/// The OSM ground `kmap recover` reads when no extract is named and the cached extracts
/// fall short: regions downloaded 1 at a time into the cache a build reads.
extension CLI {
    /// Downloads the region holding most of the map's data, the lighter of 2 alike: the run
    /// asks for a quarter of the map, so the biggest share takes the fewest downloads.
    /// False where every region under the map is cached already.
    static func downloadRegion(for img: URL, log: Log) async throws -> Bool {
        let index = RegionIndex()
        try await index.load()
        let regions = RegionSuggestion.suggestedRegions(on: RegionSuggestion.drawnGround(of: img), index: index)
            .filter { !FileTools.exists(RegionSuggestion.cacheDestination(for: $0.region)) }
        guard !regions.isEmpty else { return false }
        let weighed = await RegionSuggestion.weighed(regions)
        guard let pick = weighed.max(by: { ($0.0.share, -$0.1) < ($1.0.share, -$1.1) })?.0 ?? regions.first else {
            return false
        }
        // Said before it starts: an extract can take minutes, and the log prints after.
        let size = weighed.first { $0.0.region.id == pick.region.id }.map { ", \(Fmt.bytes($0.1))" } ?? ""
        CLILog.line("downloading \(pick.region.id)\(size), the ground recover reads")
        let fetched = try await RegionSuggestion.fetch(
            [pick.region],
            downloader: Downloader(log: log),
            connections: SettingsStore().settings.downloadConnections
        )
        guard fetched else { throw CancellationError() }
        return true
    }
}
