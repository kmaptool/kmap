import Foundation

/// Every routable way and every obstacle in an extract, held as flat arrays.
///
/// Parallel `[Double]` and `[Int64]` rather than an object per way: a country-sized
/// extract holds tens of millions of points, where per-object overhead dominates.
struct RoadNetwork {
    /// Ways, as a run of point indices: way `i` owns `start[i] ..< start[i + 1]`.
    var wayID: [Int64] = []
    var start: [Int32] = [0]
    /// layer, bridge and tunnel folded into one number. Two ends only meet if they match.
    var level: [Int32] = []
    var refs: [Int64] = []
    var lat: [Double] = []
    var lon: [Double] = []

    var obstacleStart: [Int32] = [0]
    var obstacleKind: [UInt8] = []
    /// The obstacle's own word — "kerb", "retaining_wall" — as an index into `vocabulary`,
    /// and the name it carries on the map. Interned: many obstacles, few distinct words.
    var obstacleWord: [UInt8] = []
    var vocabulary: [String] = []
    /// Metres, or nan where OSM does not say.
    var obstacleHeight: [Float] = []
    var obstacleLat: [Double] = []
    var obstacleLon: [Double] = []
    /// Nodes tagged `noexit=yes`: a dead end on purpose, which the repair leaves loose.
    var noExit: Set<Int64> = []
    /// Nodes tagged as a gate: an end on one, or a landing, is not joined.
    var gates: Set<Int64> = []
    /// Ways through a building, `tunnel=building_passage`: they meet the building's wall
    /// and are streets for all that, so an end there may be joined.
    var passages: Set<Int64> = []

    var wayCount: Int { wayID.count }
    var obstacleCount: Int { obstacleKind.count }

    /// The fewest points a way or an obstacle has to keep to be a line at all.
    static let leastPoints = 2

    func points(of way: Int) -> Range<Int> {
        Int(start[way])..<Int(start[way + 1])
    }

    /// Which obstacle a point belongs to. Binary search over the run starts, so the grid
    /// can carry a bare point index and nothing wider.
    func obstacleOwning(point: Int) -> Int {
        var low = 0, high = obstacleStart.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(obstacleStart[mid]) <= point { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func obstaclePoints(of obstacle: Int) -> Range<Int> {
        Int(obstacleStart[obstacle])..<Int(obstacleStart[obstacle + 1])
    }
}
