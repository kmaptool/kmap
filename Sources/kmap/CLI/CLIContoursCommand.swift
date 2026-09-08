import Foundation

/// `kmap contours`: trace the contours of one .hgt tile and report what came out.
///
/// The summary line is the command's product; the flags below it are the tracer's own
/// instruments, each reading the traced lines from one angle. They exist so a change to
/// the tracer can be judged in numbers rather than by staring at a map.
extension CLI {

    /// What `--major` and `--medium` mean when not given: every tenth and fifth line.
    /// With the default 20 m step that is a major every 200 m and a medium every 100 m.
    private static let majorEverySteps = 10
    private static let mediumEverySteps = 5

    /// Metres between contour lines unless `--step` says otherwise.
    private static let defaultStepMetres = 20

    static func contours(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["step", "clip", "flatness", "dump-paths", "out",
                                              "major", "medium", "start-node-id",
                                              "start-way-id"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap contours <tile.hgt> [--step 20]", code: 2)
        }
        let step = flags.int("step") ?? defaultStepMetres
        do {
            let started = Date()
            let grid = try Contours.Grid(contentsOf: URL(fileURLWithPath: path))
            var tracer = Contours(grid: grid, step: step)
            if let clip = flags.value("clip"), let box = parseClip(clip) {
                tracer.clip = box
            }
            tracer.tidy = !flags.has("raw")
            if flags.has("flatness") {
                tracer.flatness = flags.double("flatness") ?? Contours.defaultFlatness
            }
            let traced = tracer.trace()
            let lines = flags.has("no-split") ? traced : Contours.split(traced)

            let seconds = Date().timeIntervalSince(started)
            summarize(lines, step: step, seconds: seconds)

            if let dump = flags.value("dump-paths") { dumpPaths(lines, toFile: dump) }
            if flags.has("deviation") { reportDeviation(grid: grid, step: step) }
            if let out = flags.value("out") { try writeAsOSM(lines, to: out, step: step, flags: flags) }
            if flags.has("collinear") { reportCollinearity(of: lines) }
            if flags.has("lengths") { reportLengths(of: lines) }
            if flags.has("per-level") { reportPerLevel(of: lines) }
            return 0
        } catch {
            return CLIOutput.failure("contours failed: \(error)")
        }
    }

    /// `--clip S,W,N,E`, or nil for anything that does not parse as four numbers.
    private static func parseClip(_ text: String)
        -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return (minLat: parts[0], minLon: parts[1], maxLat: parts[2], maxLon: parts[3])
    }

    /// The one-line census of a trace, on screen and in the structured result.
    private static func summarize(_ lines: [Contours.Line], step: Int, seconds: Double) {
        let vertices = lines.reduce(0) { $0 + $1.points.count }
        let closed = lines.filter(\.closed).count
        let levels = Set(lines.map(\.elevation)).count
        var repeats = 0
        var longest = 0
        for line in lines {
            longest = max(longest, line.points.count)
            for i in 1..<line.points.count
            where line.points[i].lat == line.points[i - 1].lat
                && line.points[i].lon == line.points[i - 1].lon {
                repeats += 1
            }
        }
        CLILog.line("lines \(lines.count), vertices \(vertices), closed \(closed),"
              + " levels \(levels), repeated \(repeats), longest \(longest)")
        CLILog.line(String(format: "traced in %.1f s", seconds))
        CLIOutput.result(["lines": .int(lines.count), "vertices": .int(vertices),
                          "closed": .int(closed), "levels": .int(levels),
                          "repeated": .int(repeats), "longest": .int(longest),
                          "step": .int(step), "seconds": .double(seconds)])
    }

    /// `--dump-paths FILE`: every line as `elevation lat lon lat lon …`, for diffing two
    /// tracers point by point.
    private static func dumpPaths(_ lines: [Contours.Line], toFile dump: String) {
        var text = ""
        for line in lines {
            text += "\(line.elevation)"
            for point in line.points {
                text += String(format: " %.10f %.10f", point.lat, point.lon)
            }
            text += "\n"
        }
        try? text.write(toFile: dump, atomically: true, encoding: .utf8)
    }

    /// `--deviation`: how far off the line the tidying pass's dropped points lay. The tile
    /// is traced again with no tidying, and every point that tidying would remove — one
    /// sitting closer to the straight run between its neighbours than the flatness
    /// threshold — reports its distance. The largest is the cost of tidying, in ground.
    private static func reportDeviation(grid: Contours.Grid, step: Int) {
        var worst = 0.0
        var keep = Contours(grid: grid, step: step)
        keep.flatness = 0
        for full in Contours.split(keep.trace()) where full.points.count > 2 {
            for i in 1..<(full.points.count - 1) {
                let a = full.points[i - 1], b = full.points[i], c = full.points[i + 1]
                let cross = (c.lon - a.lon) * (b.lat - a.lat) - (c.lat - a.lat) * (b.lon - a.lon)
                let span = ((c.lat - a.lat) * (c.lat - a.lat)
                            + (c.lon - a.lon) * (c.lon - a.lon)).squareRoot()
                if span > 0 {
                    let off = abs(cross) / span
                    if off < Contours.defaultFlatness { worst = max(worst, off) }
                }
            }
        }
        CLILog.line(String(format: "largest deviation of a removed point: %.3e degrees (%.6f mm)",
                     worst, worst * RoadRepair.metresPerDegree * 1000))
    }

    /// `--out FILE`: the lines as OSM XML, the same shape the pipeline feeds the splitter.
    private static func writeAsOSM(_ lines: [Contours.Line], to out: String, step: Int,
                                   flags: Flags) throws {
        let major = flags.int("major") ?? step * majorEverySteps
        let medium = flags.int("medium") ?? step * mediumEverySteps
        let counts = try ContourOutput.write(
            lines, to: URL(fileURLWithPath: out),
            nodeStart: flags.value("start-node-id").flatMap { Int64($0) }
                ?? ContourOutput.nodeIDBase,
            wayStart: flags.value("start-way-id").flatMap { Int64($0) }
                ?? ContourOutput.wayIDBase,
            major: major, medium: medium)
        CLILog.line("wrote \(counts.nodes) node(s) and \(counts.ways) way(s)")
    }

    /// `--collinear`: how many point triples still sit on a dead-straight run (points the
    /// tidying could have dropped and did not), and how long the segments are.
    private static func reportCollinearity(of lines: [Contours.Line]) {
        // Well below any real deviation: at this size the cross product is noise from the
        // floating point itself, so the triple is genuinely straight.
        let straight = 1e-12
        var checked = 0, flat = 0
        var segments: [Double] = []
        for line in lines {
            for i in 1..<(max(1, line.points.count - 1)) where line.points.count > 2 {
                let a = line.points[i - 1], b = line.points[i], c = line.points[i + 1]
                let cross = (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon)
                checked += 1
                if abs(cross) < straight { flat += 1 }
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
        CLILog.line(String(format: "%d triple(s), %d collinear (%.2f%%); segment median %.2f m, share under 1 m %.1f%%",
                     checked, flat, 100.0 * Double(flat) / Double(max(1, checked)),
                     segments[segments.count / 2],
                     100.0 * Double(segments.filter { $0 < 1 }.count) / Double(segments.count)))
    }

    /// `--lengths`: total drawn length per elevation, as `LEN <level> <metres>` lines a
    /// script can diff between two runs.
    private static func reportLengths(of lines: [Contours.Line]) {
        var byLevelLength: [Int: Double] = [:]
        for line in lines {
            var total = 0.0
            for i in 1..<line.points.count {
                total += metres(line.points[i - 1], line.points[i])
            }
            byLevelLength[line.elevation, default: 0] += total
        }
        for level in byLevelLength.keys.sorted() {
            CLILog.line(String(format: "LEN %d %.1f", level, byLevelLength[level] ?? 0))
        }
    }

    /// `--per-level`: line count and closed count per elevation.
    private static func reportPerLevel(of lines: [Contours.Line]) {
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

    /// Ground distance of one segment, flat-earth at this latitude — exact enough for
    /// statistics over metres-long segments.
    private static func metres(_ a: (lat: Double, lon: Double),
                               _ b: (lat: Double, lon: Double)) -> Double {
        let kx = RoadRepair.metresPerDegree * cos(a.lat * .pi / 180)
        let dx = (b.lon - a.lon) * kx, dy = (b.lat - a.lat) * RoadRepair.metresPerDegree
        return (dx * dx + dy * dy).squareRoot()
    }
}
