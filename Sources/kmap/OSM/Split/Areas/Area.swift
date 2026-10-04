import Foundation

extension TileSplitter {
    /// One tile area, in map units, half-open on its top edges.
    struct Area {
        var minLat: Int32
        var minLon: Int32
        var maxLat: Int32
        var maxLon: Int32

        /// Converts the degrees a finished tile reports back to map units. The round trip
        /// is exact: both directions scale by the same power of two.
        init(bbox: BBox) {
            self.init(
                minLat: TileSplitter.mapUnits(bbox.minLat),
                minLon: TileSplitter.mapUnits(bbox.minLon),
                maxLat: TileSplitter.mapUnits(bbox.maxLat),
                maxLon: TileSplitter.mapUnits(bbox.maxLon)
            )
        }

        init(minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32) {
            self.minLat = minLat; self.minLon = minLon
            self.maxLat = maxLat; self.maxLon = maxLon
        }

        func contains(lat: Int32, lon: Int32) -> Bool {
            lat >= minLat && lat < maxLat && lon >= minLon && lon < maxLon
        }

        /// The same rectangle with a margin all round: the ground a tile may paint beyond
        /// its own frame, and so the ground it has to be given.
        func grown(by margin: Int32) -> Area {
            Area(
                minLat: minLat - margin,
                minLon: minLon - margin,
                maxLat: maxLat + margin,
                maxLon: maxLon + margin
            )
        }
    }
}
