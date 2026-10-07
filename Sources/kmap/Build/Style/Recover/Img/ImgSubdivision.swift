import Foundation

extension ImgElements {
    struct Subdivision {
        let level: Int
        let shift: Int
        let lat: Int32
        let lon: Int32
        let width: Int
        let height: Int
        let hasPoints: Bool
        let hasIndexedPoints: Bool
        let hasLines: Bool
        let hasAreas: Bool
        let rgnStart: Int
        let rgnEnd: Int
        var extAreasOffset = 0, extAreasSize = 0
        var extLinesOffset = 0, extLinesSize = 0
        var extPointsOffset = 0, extPointsSize = 0

        /// A subdivision states its centre and its size; anything it holds is inside that.
        /// The size is doubled here, erring towards reading a subdivision too many.
        func near(_ ground: Ground) -> Bool {
            let halfLat = Int32(clamping: (height << shift) * 2 + 2)
            let halfLon = Int32(clamping: (width << shift) * 2 + 2)
            return lat &+ halfLat >= ground.minLat && lat &- halfLat <= ground.maxLat
                && lon &+ halfLon >= ground.minLon && lon &- halfLon <= ground.maxLon
        }

        /// The part of the subdivision's own rectangle inside any of the grounds, from a
        /// 4 by 4 grid of points over it.
        func share(within grounds: [Ground]) -> Double {
            let halfLat = Int64(height) << shift, halfLon = Int64(width) << shift
            var inside = 0
            for row in 0..<4 {
                for column in 0..<4 {
                    let point = Coord(
                        lat: Int32(clamping: Int64(lat) - halfLat + (2 * Int64(row) + 1) * halfLat / 4),
                        lon: Int32(clamping: Int64(lon) - halfLon + (2 * Int64(column) + 1) * halfLon / 4)
                    )
                    if grounds.contains(where: { $0.contains(point) }) { inside += 1 }
                }
            }
            return Double(inside) / 16
        }
    }
}
