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

        /// Its bytes of RGN, the extended types with the rest.
        var dataBytes: Int {
            max(0, rgnEnd - rgnStart) + max(0, extAreasSize) + max(0, extLinesSize) + max(0, extPointsSize)
        }

        /// Its own rectangle, in degrees.
        var box: BBox {
            let degrees = 360 / Double(1 << 24)
            let halfLat = Double(Int64(height) << shift) * degrees, halfLon = Double(Int64(width) << shift) * degrees
            let lat = Double(lat) * degrees, lon = Double(lon) * degrees
            return BBox(minLon: lon - halfLon, minLat: lat - halfLat, maxLon: lon + halfLon, maxLat: lat + halfLat)
        }

        /// A subdivision states its centre and its size; anything it holds is inside that.
        /// The size is doubled here, erring towards reading a subdivision too many. One
        /// beside 180 deg is near the ground on the other side of it too.
        func near(_ ground: Ground) -> Bool {
            let halfLat = Int32(clamping: (height << shift) * 2 + 2)
            let halfLon = Int32(clamping: (width << shift) * 2 + 2)
            guard lat &+ halfLat >= ground.minLat && lat &- halfLat <= ground.maxLat else { return false }
            func reaches(_ lon: Int32) -> Bool {
                lon &+ halfLon >= ground.minLon && lon &- halfLon <= ground.maxLon
            }
            return reaches(lon) || reaches(lon &- Ground.turn) || reaches(lon &+ Ground.turn)
        }
    }
}
