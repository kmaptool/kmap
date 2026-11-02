import Foundation

extension BuildPipeline {
    /// The cells a tiled source converts and asks for.
    struct DEMTileShare {
        var unconverted: [(lat: Int, lon: Int)] = []
        /// Not downloaded.
        var missing: [(lat: Int, lon: Int)] = []
        var asked: [(lat: Int, lon: Int)] = []
        var unpublished = 0
        /// Whether the list answered.
        var listed = false
    }

    func demTileShare(_ flavor: any DEMTileSource, of wanted: [(lat: Int, lon: Int)]) async -> DEMTileShare {
        var share = DEMTileShare()
        share.unconverted = wanted.filter { !FileTools.exists(flavor.cachedTile(lat: $0.lat, lon: $0.lon)) }
        share.missing = share.unconverted.filter { !FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon)) }
        // A cached build works offline.
        guard !share.missing.isEmpty else { return share }
        let list = await tileList(of: flavor)
        share.listed = list != nil
        (share.asked, share.unpublished) = Self.published(share.missing, in: list)
        return share
    }

    /// Asked once a build.
    private func tileList(of flavor: any DEMTileSource) async -> Set<String>? {
        if let kept = state.withLock({ $0.tileLists[flavor.sourceID] }) { return kept }
        let list = await ElevationCost.tileCoverage(flavor)
        state.withLock { $0.tileLists[flavor.sourceID] = list }
        return list
    }
}
