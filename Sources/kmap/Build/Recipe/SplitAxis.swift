import Foundation

enum SplitAxis {
    case longitude, latitude

    /// Kilometres per degree: along a parallel at the equator, and along a meridian.
    private static let kmPerDegreeLongitude = 111.32, kmPerDegreeLatitude = 110.57

    /// Splits along whichever way the region is widest on the ground, so the halves are
    /// roughly equal in area rather than in degrees.
    static func best(for bbox: BBox) -> SplitAxis {
        guard bbox.isValid else { return .longitude }
        let midLat = (bbox.minLat + bbox.maxLat) / 2
        let lonKm = (bbox.maxLon - bbox.minLon) * kmPerDegreeLongitude * cos(midLat * .pi / 180)
        let latKm = (bbox.maxLat - bbox.minLat) * kmPerDegreeLatitude
        return lonKm >= latKm ? .longitude : .latitude
    }
}
