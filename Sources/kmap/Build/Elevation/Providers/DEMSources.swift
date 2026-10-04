import Foundation

/// Every source kmap reads itself, found by id.
enum DEMSources {
    static let tiled: [any DEMTileSource] = CopernicusDEM.flavors + [FABDEM.v12]
    static let all: [any DEMSource] = tiled + [GEDTM30.v12]

    /// Matched by whole id, never by prefix: "copernicus1" must not select "copernicus".
    static func named(_ id: String) -> (any DEMSource)? {
        all.first { $0.sourceID == id }
    }

    static func tiled(_ id: String) -> (any DEMTileSource)? {
        tiled.first { $0.sourceID == id }
    }
}
