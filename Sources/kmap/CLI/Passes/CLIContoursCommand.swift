import Foundation

/// `kmap contours`: one .hgt tile traced, and what came out. The summary line is the
/// product; the flags below it are the tracer's own instruments, in CLIContourDiagnostics,
/// so a change to the tracer can be judged in numbers rather than by staring at a map.
extension CLI {
    /// Metres between contour lines unless `--step` says otherwise.
    private static let defaultStepMetres = 20
    /// What `--major` and `--medium` mean when not given: every tenth and fifth line.
    private static let majorEverySteps = 10
    private static let mediumEverySteps = 5

    static func contours(_ arguments: [String]) -> Int32 {
        let flags = Flags(
            arguments,
            valued: [
                "step", "clip", "flatness", "dump-paths", "out",
                "major", "medium", "start-node-id", "start-way-id"
            ]
        )
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse("usage: kmap contours <tile.hgt> [--step \(defaultStepMetres)]")
        }
        let step = flags.int("step") ?? defaultStepMetres
        do {
            let started = Date()
            let grid = try Contours.Grid(contentsOf: URL(fileURLWithPath: path))
            var tracer = Contours(grid: grid, step: step)
            if let clip = flags.value("clip"), let box = parseClip(clip) { tracer.clip = box }
            tracer.tidy = !flags.has("raw")
            if flags.has("flatness") {
                tracer.flatness = flags.double("flatness") ?? Contours.defaultFlatness
            }
            let traced = tracer.trace()
            let lines = flags.has("no-split") ? traced : Contours.split(traced)
            summarize(lines, step: step, seconds: Date().timeIntervalSince(started))

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
    private static func parseClip(_ text: String) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
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
            where line.points[i].lat == line.points[i - 1].lat && line.points[i].lon == line.points[i - 1].lon {
                repeats += 1
            }
        }
        CLILog.line(
            "lines \(lines.count), vertices \(vertices), closed \(closed),"
                + " levels \(levels), repeated \(repeats), longest \(longest)"
        )
        CLILog.line(String(format: "traced in %.1f s", seconds))
        CLIOutput.result([
            "lines": .int(lines.count), "vertices": .int(vertices),
            "closed": .int(closed), "levels": .int(levels),
            "repeated": .int(repeats), "longest": .int(longest),
            "step": .int(step), "seconds": .double(seconds)
        ])
    }

    /// `--out FILE`: the lines as OSM XML, the same shape the pipeline feeds the splitter.
    private static func writeAsOSM(_ lines: [Contours.Line], to out: String, step: Int, flags: Flags) throws {
        let counts = try ContourOutput.write(
            lines,
            to: URL(fileURLWithPath: out),
            nodeStart: flags.value("start-node-id").flatMap { Int64($0) } ?? ContourOutput.nodeIDBase,
            wayStart: flags.value("start-way-id").flatMap { Int64($0) } ?? ContourOutput.wayIDBase,
            major: flags.int("major") ?? step * majorEverySteps,
            medium: flags.int("medium") ?? step * mediumEverySteps
        )
        CLILog.line("wrote \(counts.nodes) node(s) and \(counts.ways) way(s)")
    }
}
