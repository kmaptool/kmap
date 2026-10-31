import Foundation

/// Longitude as a circle: -180 deg and +180 deg are 1 meridian.
enum LongitudeCircle {
    /// The widest gap between the spans, when wider than the stretch through 180 deg:
    /// the spans then lie either side of the seam. Nil otherwise.
    static func gapInside(_ spans: [(west: Double, east: Double)]) -> (west: Double, east: Double)? {
        let sorted = spans.sorted { $0.west < $1.west }
        guard let first = sorted.first else { return nil }
        var widest = (west: 0.0, east: 0.0)
        var reach = first.east
        for span in sorted.dropFirst() {
            if span.west - reach > widest.east - widest.west { widest = (reach, span.west) }
            reach = max(reach, span.east)
        }
        // The stretch through 180 deg, off both ends of the spans.
        let outside = (180 - reach) + (first.west + 180)
        return widest.east - widest.west > outside ? widest : nil
    }
}
