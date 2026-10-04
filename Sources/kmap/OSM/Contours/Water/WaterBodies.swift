import Foundation

/// The standing water of an extract, as rings: what a contour stops at.
///
/// A topographic map does not draw a contour across a lake. The surface is level, so the
/// line runs to the shore and ends there. The elevation model knows nothing of OSM's
/// shorelines, and a receiver paints every line above every polygon, so the cut is made
/// here, on the geometry, before the contours are written.
struct WaterBodies: Sendable {
    /// One ring of a shoreline. `island` rings are cut back out of the water they stand in.
    struct Ring: Sendable {
        /// Latitude and longitude alternating. Single precision is a fifth of a metre
        /// here, far inside the mask's own cell.
        var points: [Float]
        var island: Bool
        /// A closed way in its own right rather than part of a multipolygon: a pond on an
        /// island is one, and is filled after the island has been cut out.
        var standalone: Bool

        var count: Int { points.count / 2 }
        func lat(_ i: Int) -> Double { Double(points[2 * i]) }
        func lon(_ i: Int) -> Double { Double(points[2 * i + 1]) }
    }

    private(set) var rings: [Ring] = []
    /// The rings touching each degree cell, by the cell's south-west corner.
    private var byCell: [Cell: [Int32]] = [:]

    private struct Cell: Hashable, Sendable {
        let lat: Int32, lon: Int32
    }

    var isEmpty: Bool { rings.isEmpty }

    /// The rings with any part in the degree cell whose south-west corner this is.
    func rings(inCellAt lat: Int, _ lon: Int) -> [Ring] {
        (byCell[Cell(lat: Int32(lat), lon: Int32(lon))] ?? []).map { rings[Int($0)] }
    }

    mutating func add(_ ring: Ring) {
        guard ring.count >= Self.fewestRingPoints else { return }
        var loLat = Double.infinity, hiLat = -Double.infinity
        var loLon = Double.infinity, hiLon = -Double.infinity
        for i in 0..<ring.count {
            loLat = min(loLat, ring.lat(i)); hiLat = max(hiLat, ring.lat(i))
            loLon = min(loLon, ring.lon(i)); hiLon = max(hiLon, ring.lon(i))
        }
        let index = Int32(rings.count)
        rings.append(ring)
        for lat in Int(loLat.rounded(.down))...Int(hiLat.rounded(.down)) {
            for lon in Int(loLon.rounded(.down))...Int(hiLon.rounded(.down)) {
                byCell[Cell(lat: Int32(lat), lon: Int32(lon)), default: []].append(index)
            }
        }
    }

    mutating func add(contentsOf other: WaterBodies) {
        for ring in other.rings { add(ring) }
    }

    /// A triangle and the point that closes it.
    static let fewestRingPoints = 4

    // MARK: What counts as water

    /// Standing and flowing water mapped as an area. Wetland is ground, and a glacier
    /// keeps its contours, so neither is here.
    static func isWater(key: String, value: String) -> Bool {
        switch key {
        case "natural": return value == "water"
        case "landuse": return value == "reservoir" || value == "basin"
        case "waterway": return value == "riverbank" || value == "dock"
        default: return false
        }
    }

    // MARK: Joining a multipolygon's ways into rings

    /// Member ways joined end to end, in either direction, into closed chains of node
    /// ids. A chain that never closes is dropped: half a shoreline encloses nothing.
    static func closedChains(of ways: [[Int64]]) -> [[Int64]] {
        var pieces = ways.filter { $0.count >= 2 }
        var closed: [[Int64]] = []
        while var chain = pieces.popLast() {
            var grew = true
            while grew, chain.first != chain.last {
                grew = false
                for (index, piece) in pieces.enumerated() {
                    if piece.first == chain.last {
                        chain.append(contentsOf: piece.dropFirst())
                    } else if piece.last == chain.last {
                        chain.append(contentsOf: piece.reversed().dropFirst())
                    } else if piece.last == chain.first {
                        chain.insert(contentsOf: piece.dropLast(), at: 0)
                    } else if piece.first == chain.first {
                        chain.insert(contentsOf: piece.reversed().dropLast(), at: 0)
                    } else {
                        continue
                    }
                    pieces.remove(at: index)
                    grew = true
                    break
                }
            }
            if chain.count >= fewestRingPoints, chain.first == chain.last { closed.append(chain) }
        }
        return closed
    }
}
