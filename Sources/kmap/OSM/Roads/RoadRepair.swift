import Foundation

/// Finding the road ends OSM left short of the line they were drawn for.
///
/// The loose ends are gridded rather than the segments, two orders of magnitude fewer
/// entries, and every segment is streamed past that grid.
struct RoadRepair {
    static let metresPerDegree = 111320.0

    /// Grid cell for filing the loose ends: about 55 m of latitude, comfortably wider
    /// than any gap worth closing.
    static let cellDegrees = 0.0005
    
    /// Two ends per way, and the 3 by 3 cells round one.
    static let endsPerWay = 2
    
    private static let neighbourhood = 9
    
    /// A guess at how many ways have a loose end, for the candidates' capacity.
    private static let looseShare = 4

    /// Metres per degree of longitude at a latitude.
    static func metresPerLonDegree(at lat: Double) -> Double {
        metresPerDegree * cos(lat * .pi / 180)
    }

    /// A candidate: an end of a way, and the nearest line it stops short of.
    struct Candidate {
        var way: Int32
        var atEnd: Bool                     // false: the way's first point
        var otherWay: Int32 = -1
        var segment: Int32 = -1
        var distance: Double = .infinity
        var along: Double = 0               // where on that segment the end lands, 0...1
    }

    let network: RoadNetwork
    let limit: Double

    /// Which of a way's two ends belong to no other routable way, and so may be loose.
    /// The node ids are already in a flat array, so they are sorted and counted rather
    /// than gathered into a dictionary.
    static func looseEnds(of network: RoadNetwork) -> [Bool] {
        var sorted = network.refs
        sorted.sort()
        var loose = [Bool](repeating: false, count: network.wayCount * Self.endsPerWay)
        for way in 0..<network.wayCount {
            let range = network.points(of: way)
            for (slot, point) in [range.lowerBound, range.upperBound - 1].enumerated() {
                loose[way * Self.endsPerWay + slot] = Self.appearsOnce(network.refs[point], in: sorted)
            }
        }
        return loose
    }

    /// Whether an id is in the list exactly once -- which is what makes an end loose.
    /// Counting the rest of a repeated id says nothing more.
    private static func appearsOnce(_ id: Int64, in sorted: [Int64]) -> Bool {
        var low = 0, high = sorted.count
        while low < high {                                  // first index not less than id
            let mid = (low + high) / 2
            if sorted[mid] < id { low = mid + 1 } else { high = mid }
        }
        guard low < sorted.count, sorted[low] == id else { return false }
        return low + 1 >= sorted.count || sorted[low + 1] != id
    }

    /// Every loose end that stops within `limit` of another line, with that line named,
    /// and the loose-end test itself, which the planner needs again for its partners.
    func candidates() -> (found: [Candidate], loose: [Bool]) {
        let loose = Self.looseEnds(of: network)
        var ends: [Candidate] = []
        ends.reserveCapacity(network.wayCount / Self.looseShare)
        for way in 0..<network.wayCount {
            if loose[way * Self.endsPerWay] { ends.append(Candidate(way: Int32(way), atEnd: false)) }
            if loose[way * Self.endsPerWay + 1] { ends.append(Candidate(way: Int32(way), atEnd: true)) }
        }

        // Each end is filed into its own cell and the eight around it, so a segment finds
        // every end within reach with one probe rather than nine.
        let cell = Self.cellDegrees
        var grid: [Int64: [Int32]] = [:]
        grid.reserveCapacity(ends.count * Self.neighbourhood)
        for (i, end) in ends.enumerated() {
            let point = self.point(of: end)
            let home = Self.key(point.lat, point.lon, cell)
            for dy in -1...1 {
                for dx in -1...1 {
                    grid[Self.neighbour(of: home, dy: dy, dx: dx), default: []].append(Int32(i))
                }
            }
        }

        for way in 0..<network.wayCount {
            let range = network.points(of: way)
            let level = network.level[way]
            for i in range.lowerBound..<(range.upperBound - 1) {
                probe(way: Int32(way), segment: i, level: level, cell: cell,
                      grid: grid, ends: &ends)
            }
        }
        return (ends.filter { $0.distance <= limit }, loose)
    }

    private func point(of end: Candidate) -> (lat: Double, lon: Double) {
        let range = network.points(of: Int(end.way))
        let at = end.atEnd ? range.upperBound - 1 : range.lowerBound
        return (network.lat[at], network.lon[at])
    }

    /// Offer one segment to every loose end near it, keeping each end's nearest.
    private func probe(way: Int32, segment: Int, level: Int32, cell: Double,
                       grid: [Int64: [Int32]], ends: inout [Candidate]) {
        let alat = network.lat[segment], alon = network.lon[segment]
        let blat = network.lat[segment + 1], blon = network.lon[segment + 1]
        let steps = max(Int(max(abs(blat - alat), abs(blon - alon)) / cell), 0) + 1
        var visited: Int64 = .min
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let here = Self.key(alat + u * (blat - alat), alon + u * (blon - alon), cell)
            if here == visited { continue }
            visited = here
            guard let bucket = grid[here] else { continue }
            for index in bucket {
                consider(end: Int(index), way: way, segment: segment, level: level,
                         alat: alat, alon: alon, blat: blat, blon: blon, ends: &ends)
            }
        }
    }

    private func consider(end index: Int, way: Int32, segment: Int, level: Int32,
                          alat: Double, alon: Double, blat: Double, blon: Double,
                          ends: inout [Candidate]) {
        var end = ends[index]
        guard end.way != way, network.level[Int(end.way)] == level else { return }
        let range = network.points(of: Int(end.way))
        let at = end.atEnd ? range.upperBound - 1 : range.lowerBound
        // A line already carrying this node is not something to join it to.
        guard network.refs[at] != network.refs[segment],
              network.refs[at] != network.refs[segment + 1] else { return }

        let plat = network.lat[at], plon = network.lon[at]
        let kx = Self.metresPerLonDegree(at: plat)
        let (distance, along) = Self.project(plat, plon, alat, alon, blat, blon, kx)
        guard distance < end.distance else { return }
        end.distance = distance
        end.along = along
        end.otherWay = way
        end.segment = Int32(segment)
        ends[index] = end
    }

    /// Distance from a point to a segment in metres, and how far along it lands.
    static func project(_ plat: Double, _ plon: Double,
                        _ alat: Double, _ alon: Double,
                        _ blat: Double, _ blon: Double, _ kx: Double) -> (Double, Double) {
        let ax = (alon - plon) * kx, ay = (alat - plat) * metresPerDegree
        let bx = (blon - plon) * kx, by = (blat - plat) * metresPerDegree
        let dx = bx - ax, dy = by - ay
        if dx == 0 && dy == 0 { return ((ax * ax + ay * ay).squareRoot(), 0) }
        let t = max(0, min(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)))
        let ox = ax + t * dx, oy = ay + t * dy
        return ((ox * ox + oy * oy).squareRoot(), t)
    }
}

extension RoadRepair {
    /// Every grid cell a segment passes through. Filing a segment under its first point
    /// alone hides the long ones, whose middles are then never looked at.
    static func cells(_ alat: Double, _ alon: Double, _ blat: Double, _ blon: Double,
                      _ cell: Double, _ body: (Int64) -> Void) {
        let steps = Int(max(abs(blat - alat), abs(blon - alon)) / cell) + 1
        var last: Int64 = .min
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let here = key(alat + u * (blat - alat), alon + u * (blon - alon), cell)
            if here != last {
                last = here
                body(here)
            }
        }
    }

    /// A cell key: the latitude cell in the high half, the longitude cell in the low.
    private static let latShift = 32
    private static let lowHalf: Int64 = 0xFFFF_FFFF
    /// x is biased to the middle of its half: the neighbour cells are probed by adding
    /// or subtracting 1, and an unbiased x of 0 or -1 would borrow into the latitude half.
    private static let lonBias: Int64 = 0x8000_0000

    static func key(_ lat: Double, _ lon: Double, _ cell: Double) -> Int64 {
        let y = Int64((lat / cell).rounded(.down))
        let x = Int64((lon / cell).rounded(.down))
        return y << latShift | ((x &+ lonBias) & lowHalf)
    }

    /// The key of the cell `dy` rows and `dx` columns away.
    static func neighbour(of key: Int64, dy: Int, dx: Int) -> Int64 {
        key &+ (Int64(dy) << latShift) &+ Int64(dx)
    }
}
