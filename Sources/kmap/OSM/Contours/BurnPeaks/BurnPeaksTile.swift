import Foundation

extension BurnPeaks {
    /// One .hgt, held as its samples with its own grid size.
    final class Tile {
        let path: URL
        var samples: [UInt8]
        let n: Int
        let lat: Int
        let lon: Int
        var dirty = false

        init(_ path: URL) throws {
            self.path = path
            self.samples = [UInt8](try Data(contentsOf: path))
            let count = samples.count / 2
            self.n = Int(Double(count).squareRoot().rounded())
            guard n >= 2, n * n * 2 == samples.count else {
                throw Trouble.notSquare(path.lastPathComponent, samples.count)
            }
            let corner = HGTName.corner(of: path.lastPathComponent)
            self.lat = corner?.lat ?? 0
            self.lon = corner?.lon ?? 0
        }

        enum Trouble: Error, CustomStringConvertible, LocalizedError {
            case notSquare(String, Int)
            var description: String {
                if case let .notSquare(name, bytes) = self {
                    return "\(name) is not square: \(bytes) bytes"
                }
                return ""
            }
        }

        /// Grid position of a coordinate: pixel-is-point, north row first.
        func index(_ latitude: Double, _ longitude: Double) -> (Int, Int)? {
            let (row, column) = place(latitude, longitude)
            guard row >= 0, row < n, column >= 0, column < n else { return nil }
            return (row, column)
        }

        /// The same, past the edges too: where a summit of a neighbour sits on this grid.
        func place(_ latitude: Double, _ longitude: Double) -> (Int, Int) {
            // Across the antimeridian a peak at 179.9 E sits just west of W180.
            var east = longitude - Double(lon)
            if east > 180 { east -= 360 } else if east < -180 { east += 360 }
            return (
                Int(((Double(lat) + 1 - latitude) * Double(n - 1)).rounded()),
                Int((east * Double(n - 1)).rounded())
            )
        }

        /// Whether the cells within `ring` of a place, on this grid or past it, reach it.
        func reaches(_ row: Int, _ column: Int, ring: Int) -> Bool {
            row + ring >= 0 && row - ring < n && column + ring >= 0 && column - ring < n
        }

        func get(_ row: Int, _ column: Int) -> Int {
            let at = (row * n + column) * 2
            return Int(Int16(bitPattern: UInt16(samples[at]) << 8 | UInt16(samples[at + 1])))
        }

        func set(_ row: Int, _ column: Int, _ value: Int) {
            let at = (row * n + column) * 2
            let bits = UInt16(bitPattern: Int16(clamping: value))
            samples[at] = UInt8(bits >> 8)
            samples[at + 1] = UInt8(bits & 0xFF)
            dirty = true
        }

        /// Raises the cells within `ring` of one to at least `value`, voids left alone.
        /// Returns how many changed.
        func raise(_ row: Int, _ column: Int, ring: Int, to value: Int) -> Int {
            guard reaches(row, column, ring: ring) else { return 0 }
            var lifted = 0
            for r in max(0, row - ring)...min(n - 1, row + ring) {
                for c in max(0, column - ring)...min(n - 1, column + ring) {
                    let held = get(r, c)
                    // Ground at exactly 0 is the sea, or nothing: a coastal summit does not
                    // raise it. Land below the sea, as by the Caspian, is raised as any.
                    guard held > BurnPeaks.void, held != 0, held < value else { continue }
                    set(r, c, value)
                    lifted += 1
                }
            }
            return lifted
        }

        /// Highest ground within the radius. The window stops at the tile edge, which can
        /// only lower it.
        func localMax(_ row: Int, _ column: Int, radius: Double, lat latitude: Double) -> Int? {
            let step = RoadRepair.metresPerDegree / Double(n - 1)
            let rows = max(1, Int((radius / step).rounded(.up)))
            let columns = max(1, Int((radius / (step * cos(latitude * .pi / 180))).rounded(.up)))
            var best: Int?
            for r in max(0, row - rows)..<min(n, row + rows + 1) {
                for c in max(0, column - columns)..<min(n, column + columns + 1) {
                    let value = get(r, c)
                    if value > BurnPeaks.void, best.map({ value > $0 }) ?? true { best = value }
                }
            }
            return best
        }
    }
}
