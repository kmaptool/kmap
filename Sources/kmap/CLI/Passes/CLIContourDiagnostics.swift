import Foundation

/// The tracer's instruments behind `kmap contours`, each reading the traced lines from
/// one angle.
extension CLI {
    /// Below this a cross product is floating-point noise, so the triple is straight.
    private static let straightBelow = 1e-12

    /// `--dump-paths FILE`: every line as `elevation lat lon lat lon ...`, for diffing two
    /// tracers point by point.
    static func dumpPaths(_ lines: [Contours.Line], toFile dump: String) {
        var text = ""
        for line in lines {
            text += "\(line.elevation)"
            for point in line.points {
                text += String(format: " %.10f %.10f", point.lat, point.lon)
            }
            text += "\n"
        }
        try? FileTools.write(text, to: URL(fileURLWithPath: dump))
    }

    /// `--deviation`: how far off the line the tidying pass's dropped points lay. The tile
    /// is traced again untidied, and every point tidying would remove reports its
    /// distance from the straight run between its neighbours. The largest is the cost of
    /// tidying, in ground.
    static func reportDeviation(grid: Contours.Grid, step: Int) {
        var worst = 0.0
        var keep = Contours(grid: grid, step: step)
        keep.flatness = 0
        for full in Contours.split(keep.trace()) where full.points.count > 2 {
            for i in 1..<(full.points.count - 1) {
                let a = full.points[i - 1], b = full.points[i], c = full.points[i + 1]
                let cross = (c.lon - a.lon) * (b.lat - a.lat) - (c.lat - a.lat) * (b.lon - a.lon)
                let span = ((c.lat - a.lat) * (c.lat - a.lat) + (c.lon - a.lon) * (c.lon - a.lon)).squareRoot()
                if span > 0 {
                    let off = abs(cross) / span
                    if off < Contours.defaultFlatness { worst = max(worst, off) }
                }
            }
        }
        CLILog.line(
            String(
                format: "largest deviation of a removed point: %.3e degrees (%.6f mm)",
                worst,
                worst * RoadRepair.metresPerDegree * 1000
            )
        )
    }

    /// `--collinear`: how many point triples still sit on a dead-straight run, points the
    /// tidying could have dropped and did not, and how long the segments are.
    static func reportCollinearity(of lines: [Contours.Line]) {
        var checked = 0, flat = 0
        var segments: [Double] = []
        for line in lines {
            for i in 1..<(max(1, line.points.count - 1)) where line.points.count > 2 {
                let a = line.points[i - 1], b = line.points[i], c = line.points[i + 1]
                let cross = (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon)
                checked += 1
                if abs(cross) < straightBelow { flat += 1 }
            }
            for i in 1..<line.points.count {
                segments.append(metres(line.points[i - 1], line.points[i]))
            }
        }
        guard !segments.isEmpty else {
            CLILog.line("no segments to measure")
            return
        }
        segments.sort()
        CLILog.line(
            String(
                format: "%d triple(s), %d collinear (%.2f%%); segment median %.2f m, share under 1 m %.1f%%",
                checked,
                flat,
                100.0 * Double(flat) / Double(max(1, checked)),
                segments[segments.count / 2],
                100.0 * Double(segments.filter { $0 < 1 }.count) / Double(segments.count)
            )
        )
    }

    /// `--lengths`: total drawn length per elevation, as `LEN <level> <metres>` lines a
    /// script can diff between two runs.
    static func reportLengths(of lines: [Contours.Line]) {
        var byLevel: [Int: Double] = [:]
        for line in lines {
            var total = 0.0
            for i in 1..<line.points.count {
                total += metres(line.points[i - 1], line.points[i])
            }
            byLevel[line.elevation, default: 0] += total
        }
        for level in byLevel.keys.sorted() {
            CLILog.line(String(format: "LEN %d %.1f", level, byLevel[level] ?? 0))
        }
    }

    /// `--per-level`: line count and closed count per elevation.
    static func reportPerLevel(of lines: [Contours.Line]) {
        var byLevel: [Int: Int] = [:]
        var closedBy: [Int: Int] = [:]
        for line in lines {
            byLevel[line.elevation, default: 0] += 1
            if line.closed { closedBy[line.elevation, default: 0] += 1 }
        }
        for level in byLevel.keys.sorted() {
            CLILog.line("  \(level) m: \(byLevel[level] ?? 0) \(closedBy[level] ?? 0)")
        }
    }

    /// Ground distance of one segment, flat-earth at this latitude: exact enough for
    /// statistics over metres-long segments.
    private static func metres(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let kx = RoadRepair.metresPerDegree * cos(a.lat * .pi / 180)
        let dx = (b.lon - a.lon) * kx, dy = (b.lat - a.lat) * RoadRepair.metresPerDegree
        return (dx * dx + dy * dy).squareRoot()
    }
}
