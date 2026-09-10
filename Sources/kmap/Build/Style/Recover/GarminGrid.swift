import Foundation

/// The coordinate grid a compiled map lives on: 24-bit map units, degrees × 2²⁴/360, about
/// 2.4 m per step at the equator. Every vertex sits exactly on this grid, so an OSM node
/// rounded onto it either equals the map's vertex or does not.
enum GarminGrid {
    static let unitsPerDegree = Double(1 << 24) / 360.0

    /// The finest resolution, where a vertex sits exactly on the grid.
    static let fullResolution = 24

    /// A way of two vertices is one edge; a ring is a triangle and its closing vertex.
    static let edgeVertices = 2
    static let ringVertices = 4

    static func unit(_ degrees: Double) -> Int32 {
        Int32((degrees * unitsPerDegree).rounded())
    }

    /// One grid cell packed into a single value, for hashing.
    static func cell(lat: Double, lon: Double) -> UInt64 {
        pack(latUnit: unit(lat), lonUnit: unit(lon))
    }

    static func pack(latUnit: Int32, lonUnit: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: latUnit)) << 32 | UInt64(UInt32(bitPattern: lonUnit))
    }

    /// An FNV-1a hash over three consecutive cells: the unit of matching. One vertex is
    /// shared by many ways, three identify a stretch of one. Mixed rather than concatenated,
    /// folding 192 bits into 64; the matcher requires a run of grams, so collisions are cheap.
    static func gram(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for v in [a, b, c] {
            h ^= v
            h = h &* 0x100000001b3
        }
        return h
    }

    /// The area a closed chain of cells encloses, in map units squared: what a fill
    /// covers, as the eye weighs it. Sign dropped, so the winding does not matter.
    static func area<Chain: RandomAccessCollection>(of cells: Chain) -> Double
    where Chain.Element == UInt64, Chain.Index == Int {
        guard cells.count >= ringVertices else { return 0 }
        var twice = 0.0
        var previous = cells[cells.startIndex + cells.count - 1]
        for cell in cells {
            let (lat, lon) = unpack(cell), (lastLat, lastLon) = unpack(previous)
            twice += lastLon * lat - lon * lastLat
            previous = cell
        }
        return abs(twice) / 2
    }

    private static func unpack(_ cell: UInt64) -> (lat: Double, lon: Double) {
        (Double(Int32(bitPattern: UInt32(cell >> 32))),
         Double(Int32(bitPattern: UInt32(cell & 0xFFFF_FFFF))))
    }

    /// The cell as a zoomed-out level stores it: each coordinate rounded to the
    /// level's lattice, 2^shift units wide. mkgmap rounds, and its subdivisions sit
    /// on the lattice, so a node of the ground lands exactly where the map put it.
    static func onLattice(_ cell: UInt64, shift: Int) -> UInt64 {
        guard shift > 0 else { return cell }
        let half = Int32(1 << (shift - 1))
        func snap(_ v: Int32) -> Int32 { ((v &+ half) >> shift) << shift }
        return pack(latUnit: snap(Int32(bitPattern: UInt32(cell >> 32))),
                    lonUnit: snap(Int32(bitPattern: UInt32(cell & 0xFFFF_FFFF))))
    }

    /// The one edge of a two-vertex way, hashed apart from the triples.
    static func edge(_ a: UInt64, _ b: UInt64) -> UInt64 { gram(a, b, .max) }

    /// All grams of a vertex chain, in order. Empty below three vertices: a point is
    /// matched by its cell, a two-vertex way by its `edge`.
    static func grams<Chain: RandomAccessCollection>(of cells: Chain) -> [UInt64]
    where Chain.Element == UInt64, Chain.Index == Int {
        guard cells.count >= 3 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(cells.count - 2)
        let base = cells.startIndex
        for i in 0..<(cells.count - 2) {
            out.append(gram(cells[base + i], cells[base + i + 1], cells[base + i + 2]))
        }
        return out
    }

    /// The grams of the chain read backwards without reversing the chain, for a way mkgmap
    /// wrote in the opposite direction.
    static func gramsReversed<Chain: RandomAccessCollection>(of cells: Chain) -> [UInt64]
    where Chain.Element == UInt64, Chain.Index == Int {
        guard cells.count >= 3 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(cells.count - 2)
        let last = cells.startIndex + cells.count - 1
        for i in 0..<(cells.count - 2) {
            out.append(gram(cells[last - i], cells[last - i - 1], cells[last - i - 2]))
        }
        return out
    }
}
