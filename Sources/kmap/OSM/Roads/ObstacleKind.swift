import Foundation

/// What an obstacle is, in one byte. The raw values match `obstacle_kind()` in the
/// reference Python tool.
enum ObstacleKind: UInt8 {
    case fence = 0  // a plot boundary: never crossed, at any height
    case building = 1  // no route was meant to go through a house
    case cliff = 2
    case ravine = 3
    case water = 4  // river or canal; a stream is not an obstacle to a walker
    case embankment = 5
    case barrier = 6  // a kerb, a guard rail, a chain: crossable, and marked when crossed

    var isImpassable: Bool { self == .fence || self == .building }
}
