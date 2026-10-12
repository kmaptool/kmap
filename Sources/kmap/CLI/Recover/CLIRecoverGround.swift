import Foundation

/// The OSM ground `kmap recover` reads when no extract is named and the cached extracts
/// fall short: regions downloaded 1 at a time into the cache a build reads.
extension CLI {
    /// Downloads the region holding most of the map's data among those not cached yet.
    /// False where every region under the map is cached already.
    static func downloadRegion(for img: URL, log: Log) async throws -> Bool {
        let index = RegionIndex()
        try await index.load()
        let drawn = RegionSuggestion.drawnGround(of: img)
        // Where the map draws on no leaf of its own, the regions the screen would offer.
        let leaves = RegionSuggestion.drawnOnLeaves(on: drawn, index: index)
        let regions = (leaves.isEmpty ? RegionSuggestion.suggestedRegions(on: drawn, index: index) : leaves)
            .filter { !FileTools.exists(RegionSuggestion.cacheDestination(for: $0.region)) }
        // Biggest share first: the run asks for a share of the map, so it takes the fewest.
        guard let pick = regions.first?.region else { return false }
        // Said before it starts: an extract can take minutes, and the log prints after.
        var size = ""
        if let url = pick.pbfURL, let info = try? await Downloader.probe(url) { size = ", \(Fmt.bytes(info.size))" }
        CLILog.line("downloading \(pick.id)\(size), the ground recover reads")
        let fetched = try await RegionSuggestion.fetch(
            [pick],
            downloader: Downloader(log: log),
            connections: SettingsStore().settings.downloadConnections
        )
        guard fetched else { throw CancellationError() }
        return true
    }
}
