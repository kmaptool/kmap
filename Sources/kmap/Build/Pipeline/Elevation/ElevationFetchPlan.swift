import Foundation

extension BuildPipeline {
    /// The cells each fetch will download, as on disk before any runs.
    func fetchWeights(_ steps: [FetchStep]) async -> [Double] {
        var claimed = Set<String>()
        var weights: [Double] = []
        // The cells left to a fetch whose first source is `id`.
        func left(for id: String) -> [(lat: Int, lon: Int)] {
            let earlier = earlierSourceDirectories(before: id)
            return elevationCells().filter {
                !claimed.contains(HGTName.of(lat: $0.lat, lon: $0.lon))
                    && !cellSettledEarlier(earlier, lat: $0.lat, lon: $0.lon)
            }
        }
        func claim(_ cells: [(lat: Int, lon: Int)]) {
            claimed.formUnion(cells.map { HGTName.of(lat: $0.lat, lon: $0.lon) })
        }
        for step in steps {
            switch step {
            case .direct(let source):
                let cells = left(for: source.sourceID)
                if let tiled = source as? any DEMTileSource {
                    // A downloaded tile is converted, not fetched.
                    let share = await demTileShare(tiled, of: cells)
                    let downloaded = share.unconverted.filter {
                        FileTools.exists(tiled.downloadedTif(lat: $0.lat, lon: $0.lon))
                    }
                    claim(downloaded + share.asked)
                    weights.append(Double(share.asked.count))
                } else if let gedtm = source as? GEDTM30 {
                    claim(cells)
                    weights.append(Double(cells.filter { !gedtm.isDone(lat: $0.lat, lon: $0.lon) }.count))
                } else {
                    weights.append(0)
                }
            case .viewfinder(let resolutions):
                guard let first = resolutions.first else {
                    weights.append(0)
                    continue
                }
                let cells = left(for: ViewfinderDEM.sourceID(first))
                claim(cells)
                // The fetch loads every index first.
                let fetched = cells.filter {
                    Self.viewfinderFetches(HGTName.of(lat: $0.lat, lon: $0.lon), resolutions: resolutions) { _ in true }
                }
                weights.append(Double(fetched.count))
            case .credentialed(let sources):
                let reachable = Self.reachable(sources, usable: ElevationLogins.usable)
                guard let first = reachable.first, let id = sources.first else {
                    weights.append(0)
                    continue
                }
                let cells = left(for: id)
                claim(cells)
                weights.append(Double(Self.pyhgtmapFetching(cells, first: first).count))
            }
        }
        return weights
    }

    /// Whether Viewfinder downloads `cell`.
    static func viewfinderFetches(_ cell: String, resolutions: [Int], indexed: (Int) -> Bool) -> Bool {
        for resolution in resolutions {
            if ViewfinderDEM.isComplete(ViewfinderDEM.cachedTile(cell, resolution: resolution), resolution: resolution)
            {
                return false
            }
            if indexed(resolution) { return true }
        }
        return false
    }

    /// The cells pyhgtmap downloads.
    static func pyhgtmapFetching(_ cells: [(lat: Int, lon: Int)], first: String) -> Set<String> {
        Set(
            cells.map { HGTName.of(lat: $0.lat, lon: $0.lon) }.filter {
                !FileTools.exists(pyhgtmapDirectory(first).appendingPathComponent("\($0).tif"))
            }
        )
    }
}
