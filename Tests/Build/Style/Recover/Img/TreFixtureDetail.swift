import Foundation

extension TreFixture {
    /// A detail subdivision: its centre and half its size in degrees, and its bytes of
    /// RGN: those given, or its points' where it has any.
    struct Detail {
        let lon: Double, lat: Double
        let halfLon: Double, halfLat: Double
        var bytes = 0
        var points: [Point] = []

        var rgnBytes: Int { points.isEmpty ? bytes : points.reduce(0) { $0 + ($1.sub == nil ? 8 : 9) } }
    }
}
