import Foundation

/// Where the contour stage's time actually goes.
///
/// Off unless `KMAP_CONTOUR_TIMING` is set, and the question is asked once rather than per
/// cell -- a `ProcessInfo` lookup inside a loop over thirteen million cells is how a
/// thirty-eight second pass became a twenty-four minute one, elsewhere in this build.
///
/// Two things are recorded. The phases say what the work *is*: reading the grid, sweeping
/// it, stitching the crossings into lines, cutting them to the region, writing them out.
/// The per-cell records say how the lanes were *filled* -- when each cell started and how
/// long it ran -- because a stage can be slow either from doing expensive work or from
/// doing it in the wrong order, and the two look identical from the outside.
enum ContourTiming {
    static let on = ProcessInfo.processInfo.environment["KMAP_CONTOUR_TIMING"] != nil

    private static let lock = NSLock()
    private static var totals: [String: Double] = [:]
    private static var order: [String] = []
    private static var cells: [(index: Int, name: String, start: Double,
                                seconds: Double, points: Int)] = []
    private static var origin = DispatchTime.now().uptimeNanoseconds

    static func begin() {
        guard on else { return }
        lock.lock()
        totals = [:]; order = []; cells = []
        origin = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// Seconds since the stage began, for placing a cell on the timeline.
    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- origin) / 1e9
    }

    @inline(__always)
    static func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        guard on else { return try body() }
        let started = DispatchTime.now().uptimeNanoseconds
        let out = try body()
        add(phase, Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9)
        return out
    }

    static func add(_ phase: String, _ seconds: Double) {
        guard on else { return }
        lock.lock()
        if totals[phase] == nil { order.append(phase) }
        totals[phase, default: 0] += seconds
        lock.unlock()
    }

    static func cell(index: Int, name: String, start: Double, seconds: Double, points: Int) {
        guard on else { return }
        lock.lock()
        cells.append((index, name, start, seconds, points))
        lock.unlock()
    }

    /// A floor under the divisors, so an empty stage reports zeros rather than NaN.
    private static let leastSeconds = 0.001

    /// The report, as lines for the build log.
    static func report(wall: Double, lanes: Int) -> [String] {
        guard on else { return [] }
        lock.lock()
        let totals = self.totals, order = self.order, cells = self.cells
        lock.unlock()
        guard !cells.isEmpty else { return [] }

        var out: [String] = []
        let busy = totals.values.reduce(0, +)
        out.append(String(format: "contour timing: %.1f s wall, %.1f s of work in %d lane(s)"
                          + " — %.1f cores' worth", wall, busy, lanes, busy / max(wall, leastSeconds)))
        for phase in order {
            let seconds = totals[phase] ?? 0
            out.append(String(format: "  %-10@ %7.1f s  %5.1f%% of work  %5.1f%% of wall",
                              phase as NSString, seconds, 100 * seconds / max(busy, leastSeconds),
                              100 * seconds / max(wall, leastSeconds) / Double(lanes)))
        }

        // The tail: a stage with ten lanes and one four-minute cell spends its last four
        // minutes at one core no matter how the rest went.
        let sorted = cells.sorted { $0.seconds > $1.seconds }
        let ends = cells.map { $0.start + $0.seconds }.sorted()
        let last = ends.last ?? 0
        var alone = 0.0
        // How much of the stage ran with fewer than half the lanes occupied.
        let starts = cells.map(\.start).sorted()
        var events: [(at: Double, delta: Int)] = starts.map { ($0, 1) } + ends.map { ($0, -1) }
        events.sort { $0.at < $1.at }
        var running = 0
        var previous = 0.0
        var occupancy = 0.0
        for event in events {
            if running > 0 { occupancy += Double(running) * (event.at - previous) }
            if running < max(1, lanes / 2) && running > 0 { alone += event.at - previous }
            running += event.delta
            previous = event.at
        }
        out.append(String(format: "  %d cell(s); mean occupancy %.1f lane(s);"
                          + " %.1f s (%.0f%%) below half the lanes",
                          cells.count, occupancy / max(last, leastSeconds), alone,
                          100 * alone / max(last, leastSeconds)))
        out.append("  slowest cell(s): " + sorted.prefix(5).map {
            String(format: "%@ %.1f s (starts at %.1f)", $0.name, $0.seconds, $0.start)
        }.joined(separator: ", "))
        let points = cells.reduce(0) { $0 + $1.points }
        out.append(String(format: "  %d point(s) traced, %.2f µs each of work",
                          points, busy * 1e6 / Double(max(points, 1))))
        return out
    }
}
