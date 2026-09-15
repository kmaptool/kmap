import Foundation

/// The tile the tracer reads and the lines it writes.
extension Contours {
    struct Grid {
        var samples: [Int16]
        var n: Int
        /// South-west corner, whole degrees.
        var lat: Int
        var lon: Int

        func value(_ row: Int, _ column: Int) -> Int {
            Int(samples[row * n + column])
        }

        /// Row 0 is the north edge, as a .hgt stores it.
        func latitude(_ row: Double) -> Double {
            Double(lat) + 1 - row / Double(n - 1)
        }

        func longitude(_ column: Double) -> Double {
            Double(lon) + column / Double(n - 1)
        }

        /// For a caller that already holds the samples.
        init(samples: [Int16], n: Int, lat: Int, lon: Int) {
            self.samples = samples
            self.n = n
            self.lat = lat
            self.lon = lon
        }

        init(contentsOf url: URL) throws {
            let data = try Data(contentsOf: url)
            let sampleSize = MemoryLayout<Int16>.size
            let count = data.count / sampleSize
            let side = Int(Double(count).squareRoot().rounded())
            guard side * side * sampleSize == data.count else {
                throw Trouble.notSquare(url.lastPathComponent)
            }
            var values = [Int16](repeating: 0, count: count)
            // Big-endian, as a .hgt stores its samples.
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    values[i] = Int16(bitPattern: UInt16(raw[i * sampleSize]) << UInt8.bitWidth
                                      | UInt16(raw[i * sampleSize + 1]))
                }
            }
            self.samples = values
            self.n = side
            let corner = HGTName.corner(of: url.lastPathComponent)
            self.lat = corner?.lat ?? 0
            self.lon = corner?.lon ?? 0
        }
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case notSquare(String)
        var description: String {
            if case let .notSquare(name) = self { return "\(name) is not a square .hgt" }
            return ""
        }
    }

    /// The most vertices one way may carry, matching pyhgtmap's limit.
    static let maxPoints = 2000

    /// Splits lines longer than `maxPoints`. Each piece repeats the vertex it shares with
    /// the next, so the line stays joined.
    static func split(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines {
            guard line.points.count > maxPoints else {
                out.append(line)
                continue
            }
            var at = 0
            while at < line.points.count - 1 {
                let end = min(at + maxPoints, line.points.count)
                out.append(Line(elevation: line.elevation,
                                points: Array(line.points[at..<end]), closed: false))
                at = end - 1
            }
        }
        return out
    }

    /// One traced line at one elevation.
    struct Line {
        var elevation: Int
        var points: [(lat: Double, lon: Double)]
        var closed: Bool
    }
}
