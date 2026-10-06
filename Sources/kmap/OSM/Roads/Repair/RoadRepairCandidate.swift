import Foundation

extension RoadRepair {
    /// A candidate: an end of a way, and the nearest line it stops short of.
    struct Candidate {
        var way: Int32
        var atEnd: Bool  // false: the way's first point
        var otherWay: Int32 = -1
        var segment: Int32 = -1
        var distance: Double = .infinity
        var along: Double = 0  // where on that segment the end lands, 0...1
    }
}
