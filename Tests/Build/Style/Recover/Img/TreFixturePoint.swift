import Foundation

extension TreFixture {
    /// A point of a subdivision: its type's first byte, and where it sits from the
    /// subdivision's centre, in map units.
    struct Point {
        let type: Int
        /// The type's second byte, where it has one.
        var sub: Int?
        var dLon = 0
        var dLat = 0
    }
}
