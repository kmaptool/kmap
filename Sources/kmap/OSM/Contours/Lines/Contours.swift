import Foundation

/// Traces contour lines across a .hgt tile by marching squares.
///
/// A crossing always sits on one edge of one cell, so it is identified by that edge rather
/// than by its coordinates: segments meet when their edge keys are equal, an integer
/// comparison. Coordinates are resolved once, at the end.
struct Contours {
    /// A cell owns two of its edges, east and south; the other two belong to neighbours.
    private static let edgesPerCell = 2

    /// Below this a sample is a void, not ground. A cell holding one is skipped entirely:
    /// interpolating between ground and nodata invents a cliff.
    static let void = -32000

    let grid: Grid
    /// Metres between lines.
    let step: Int
    /// When false, every crossing is kept, duplicates included, for comparison against
    /// another tracer.
    var tidy = true
    /// How far off the straight line a point may sit and still be dropped, in degrees.
    /// The default is about a millimetre of ground: far below what any device draws.
    static let defaultFlatness = 1e-8
    var flatness = Contours.defaultFlatness
    /// Contour only inside this box. Elevation tiles are whole degrees while a region is
    /// not, so a cell is clipped to the region. pyhgtmap masks the samples instead.
    var clip: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)?

    private func outside(_ row: Int, _ column: Int) -> Bool {
        guard let clip else { return false }
        let lat = grid.latitude(Double(row)), lon = grid.longitude(Double(column))
        return lat < clip.minLat || lat > clip.maxLat || lon < clip.minLon || lon > clip.maxLon
    }

    /// The rows and columns the clip box can reach, with one row and column of slack at each
    /// edge so `outside` remains the deciding test. The whole grid where there is no clip.
    private func clipBounds() -> (rows: Range<Int>, columns: Range<Int>) {
        let whole = 0..<grid.n
        guard let clip else { return (whole, whole) }
        let span = Double(grid.n - 1)
        let top = ((Double(grid.lat) + 1 - clip.maxLat) * span).rounded(.down) - 1
        let bottom = ((Double(grid.lat) + 1 - clip.minLat) * span).rounded(.up) + 1
        let left = ((clip.minLon - Double(grid.lon)) * span).rounded(.down) - 1
        let right = ((clip.maxLon - Double(grid.lon)) * span).rounded(.up) + 1
        func clamp(_ value: Double) -> Int { max(0, min(grid.n - 1, Int(value))) }
        let rows = clamp(top)..<(clamp(bottom) + 1)
        let columns = clamp(left)..<(clamp(right) + 1)
        return (rows.isEmpty ? whole : rows, columns.isEmpty ? whole : columns)
    }

    /// Every contour in the tile, at every multiple of `step` the ground reaches. One sweep
    /// of the grid serves all levels: a cell's four corners bound which levels can cross it.
    func trace() -> [Line] {
        let bounds = clipBounds()
        var lowest = Int.max, highest = Int.min
        ContourTiming.measure("range") {
            for row in bounds.rows {
                for column in bounds.columns {
                    let value = grid.value(row, column)
                    guard value > Self.void, !outside(row, column) else { continue }
                    lowest = min(lowest, value)
                    highest = max(highest, value)
                }
            }
        }
        guard lowest <= highest, step > 0 else { return [] }

        let base = Int((Double(lowest) / Double(step)).rounded(.down)) * step
        var levels: [Int] = []
        var level = base
        while level <= highest {
            levels.append(level)
            level += step
        }
        guard !levels.isEmpty else { return [] }

        var sweep = (0..<levels.count).map { _ in Level(width: grid.n) }
        ContourTiming.measure("collect") {
            collect(into: &sweep, base: base, bounds: bounds)
        }

        var lines: [Line] = []
        ContourTiming.measure("assemble") {
            for (index, level) in levels.enumerated() {
                lines.append(contentsOf: assemble(&sweep[index], level: level))
            }
        }
        return lines
    }

    /// Marching squares over every cell, filing each crossing under the level it belongs
    /// to. Which levels a cell can hold follows from its lowest and highest corner.
    private func collect(
        into sweep: inout [Level],
        base: Int,
        bounds: (
            rows: Range<Int>,
            columns: Range<Int>
        )
    ) {
        let n = grid.n
        let clipping = clip != nil

        for row in bounds.rows.lowerBound..<min(bounds.rows.upperBound, n - 1) {
            for column in bounds.columns.lowerBound..<min(bounds.columns.upperBound, n - 1) {
                let topLeft = grid.value(row, column)
                let topRight = grid.value(row, column + 1)
                let bottomLeft = grid.value(row + 1, column)
                let bottomRight = grid.value(row + 1, column + 1)
                guard topLeft > Self.void, topRight > Self.void,
                    bottomLeft > Self.void, bottomRight > Self.void
                else { continue }

                // A level crosses an edge only when one corner is above it and the other is
                // not, so the levels run from the cell's lowest corner to just under its
                // highest.
                let low = min(min(topLeft, topRight), min(bottomLeft, bottomRight))
                let high = max(max(topLeft, topRight), max(bottomLeft, bottomRight))
                guard low < high else { continue }
                let first = max(0, Self.stepsUp(low - base, step))
                let last = min(sweep.count - 1, Self.stepsUp(high - base, step) - 1)
                guard first <= last else { continue }

                if clipping,
                    outside(row, column) || outside(row, column + 1)
                        || outside(row + 1, column) || outside(row + 1, column + 1)
                {
                    continue
                }

                for index in first...last {
                    cell(
                        row: row,
                        column: column,
                        n: n,
                        level: base + index * step,
                        corners: (topLeft, topRight, bottomLeft, bottomRight),
                        into: &sweep,
                        at: index
                    )
                }
            }
        }
    }

    /// How many whole steps reach `distance`, rounding up. Written out because Swift's
    /// integer division rounds towards zero and `distance` can be negative.
    private static func stepsUp(_ distance: Int, _ step: Int) -> Int {
        distance >= 0 ? (distance + step - 1) / step : -((-distance) / step)
    }

    /// One cell at one level: where the contour cuts its edges, and what joins to what.
    private func cell(
        row: Int,
        column: Int,
        n: Int,
        level: Int,
        corners: (Int, Int, Int, Int),
        into sweep: inout [Level],
        at index: Int
    ) {
        let (topLeft, topRight, bottomLeft, bottomRight) = corners

        func cut(_ a: Int, _ b: Int) -> Double? {
            // "Above" is strictly above: elevations are whole metres and levels are
            // multiples of the step, so samples landing exactly on a level are common, and
            // "at or above" would lose every such crossing.
            guard (a > level) != (b > level) else { return nil }
            return Double(level - a) / Double(b - a)
        }

        // Named rather than collected into a list: which edge is which decides how a saddle
        // is joined, and pairing by key order would cross the two arcs.
        var top: Int32?, bottom: Int32?, left: Int32?, right: Int32?
        if let t = cut(topLeft, topRight) {
            top = sweep[index].east(
                row: Int32(row),
                column: column,
                key: edgeKey(row, column, south: false),
                at: t
            )
        }
        if let t = cut(bottomLeft, bottomRight) {
            bottom = sweep[index].east(
                row: Int32(row + 1),
                column: column,
                key: edgeKey(row + 1, column, south: false),
                at: t
            )
        }
        if let t = cut(topLeft, bottomLeft) {
            left = sweep[index].south(
                row: Int32(row),
                column: column,
                key: edgeKey(row, column, south: true),
                at: t
            )
        }
        if let t = cut(topRight, bottomRight) {
            right = sweep[index].south(
                row: Int32(row),
                column: column + 1,
                key: edgeKey(row, column + 1, south: true),
                at: t
            )
        }

        // Two or four, never one or three: round the four corners, the number of edges where
        // "above the level" changes is even.
        let here = [top, bottom, left, right].compactMap { $0 }
        switch here.count {
        case 2:
            sweep[index].join(here[0], here[1])
        case 4:
            // A saddle: the two arcs cut off one pair of opposite corners, chosen by the
            // cell's mean. Above the level the low corners are the pockets; at or below it
            // the high ones are. Matches contourpy. All four edges are crossed here.
            guard let top, let right, let left, let bottom else { break }
            let middle = Double(topLeft + topRight + bottomLeft + bottomRight) / 4
            if (middle > Double(level)) == (topLeft > level) {
                sweep[index].join(top, right); sweep[index].join(left, bottom)
            } else {
                sweep[index].join(top, left); sweep[index].join(right, bottom)
            }
        default:
            break
        }
    }

    /// A crossing is named by the edge it sits on: `(row, column)` of the cell corner the
    /// edge starts at, and whether it runs east or south from there.
    private func edgeKey(_ row: Int, _ column: Int, south: Bool) -> Int32 {
        Int32(((row * grid.n) + column) * Self.edgesPerCell + (south ? 1 : 0))
    }

    /// The position of a crossing, from its edge key and how far along that edge it sits.
    private func place(_ key: Int32, _ along: Double) -> (lat: Double, lon: Double) {
        let south = key & 1 == 1
        let cell = Int(key >> 1)
        let row = cell / grid.n, column = cell % grid.n
        return south
            ? (grid.latitude(Double(row) + along), grid.longitude(Double(column)))
            : (grid.latitude(Double(row)), grid.longitude(Double(column) + along))
    }

    /// Walks the segments into lines: open ones first from their loose ends, then whatever
    /// remains, which can only be closed rings.
    private func assemble(_ sweep: inout Level, level: Int) -> [Line] {
        let count = sweep.along.count
        guard count > 0 else { return [] }
        // Moved into locals so the links are uniquely referenced and the walk writes in
        // place. The rolling row is finished with, and dropping it frees it before the walk.
        sweep.eastID = []; sweep.eastRow = []
        sweep.southID = []; sweep.southRow = []
        let along = sweep.along, edge = sweep.edge
        var linkA = sweep.linkA; sweep.linkA = []
        var linkB = sweep.linkB; sweep.linkB = []

        // Ascending by edge key, which fixes which end of an open line becomes its first
        // point and hence the node order in the file.
        let order = Self.byEdge(edge)

        var lines: [Line] = []

        func detach(_ from: Int32, _ what: Int32) {
            if linkA[Int(from)] == what {
                linkA[Int(from)] = -1
            } else if linkB[Int(from)] == what {
                linkB[Int(from)] = -1
            }
        }

        func walk(from start: Int32) -> [Int32] {
            var path = [start]
            var current = start
            while true {
                let first = linkA[Int(current)]
                let next = first >= 0 ? first : linkB[Int(current)]
                guard next >= 0 else { break }
                detach(current, next)
                detach(next, current)
                path.append(next)
                current = next
                if next == start { break }
            }
            return path
        }

        func emit(_ path: [Int32]) {
            guard path.count >= 2 else { return }
            // A crossing landing exactly on a grid node belongs to both edges meeting there,
            // so the same position arrives twice in a row.
            var points: [(lat: Double, lon: Double)] = []
            points.reserveCapacity(path.count)
            for id in path {
                let point = place(edge[Int(id)], along[Int(id)])
                if tidy, let last = points.last, last.lat == point.lat, last.lon == point.lon {
                    continue
                }
                points.append(point)
            }
            // A contour running along a grid line crosses every perpendicular edge, putting
            // those crossings on one straight run; the collinear ones are dropped.
            var kept: [(lat: Double, lon: Double)] = []
            kept.reserveCapacity(points.count)
            for point in points {
                // Folds back over the whole run, since a run can be straight throughout. The
                // test is the middle point's distance off the line against `flatness`, not
                // an exact zero cross product, which floating-point crossings never give.
                while tidy, kept.count >= 2 {
                    let a = kept[kept.count - 2], b = kept[kept.count - 1]
                    let cross =
                        (b.lon - a.lon) * (point.lat - a.lat)
                        - (b.lat - a.lat) * (point.lon - a.lon)
                    let span =
                        ((point.lat - a.lat) * (point.lat - a.lat)
                        + (point.lon - a.lon) * (point.lon - a.lon)).squareRoot()
                    if span == 0 || abs(cross) / span > flatness { break }
                    // Collinear is not enough: the middle point must lie between the other
                    // two, or dropping it would cut the tip off a spike that doubles back.
                    let along =
                        (b.lat - a.lat) * (point.lat - a.lat)
                        + (b.lon - a.lon) * (point.lon - a.lon)
                    let reach =
                        (b.lat - a.lat) * (b.lat - a.lat)
                        + (b.lon - a.lon) * (b.lon - a.lon)
                    if along <= 0 || reach > span * span { break }
                    kept.removeLast()
                }
                kept.append(point)
            }
            guard kept.count >= 2 else { return }
            lines.append(
                Line(
                    elevation: level,
                    points: kept,
                    closed: path.first == path.last
                )
            )
        }

        // Loose ends first, so an open contour is walked from one of its ends and comes out
        // whole; anything still linked after that can only be a closed ring.
        for id in order {
            let degree = (linkA[Int(id)] >= 0 ? 1 : 0) + (linkB[Int(id)] >= 0 ? 1 : 0)
            if degree == 1 { emit(walk(from: id)) }
        }
        for id in order where linkA[Int(id)] >= 0 || linkB[Int(id)] >= 0 {
            emit(walk(from: id))
        }
        return lines
    }

    /// The crossings of a level in ascending order of the edge each sits on, and by
    /// number where 2 share an edge. A radix sort, 11 bits a pass: the keys are small
    /// whole numbers, and each pass keeps the order the one before left.
    static func byEdge(_ edge: [Int32]) -> [Int32] {
        let count = edge.count
        var order = [Int32](unsafeUninitializedCapacity: count) { ids, filled in
            for id in 0..<count { ids[id] = Int32(id) }
            filled = count
        }
        guard count > 1 else { return order }
        let digitBits = 11, buckets = 1 << digitBits
        var scratch = [Int32](repeating: 0, count: count)
        var starts = [Int](repeating: 0, count: buckets)
        edge.withUnsafeBufferPointer { edge in
            var highest: UInt32 = 0
            for key in edge { highest = max(highest, UInt32(bitPattern: key)) }
            let passes = max(1, (UInt32.bitWidth - highest.leadingZeroBitCount + digitBits - 1) / digitBits)
            for pass in 0..<passes {
                let shift = UInt32(pass * digitBits), mask = UInt32(buckets - 1)
                order.withUnsafeBufferPointer { from in
                    scratch.withUnsafeMutableBufferPointer { to in
                        starts.withUnsafeMutableBufferPointer { starts in
                            starts.update(repeating: 0)
                            for id in from {
                                starts[Int(UInt32(bitPattern: edge[Int(id)]) >> shift & mask)] += 1
                            }
                            var at = 0
                            for bucket in 0..<buckets {
                                let held = starts[bucket]
                                starts[bucket] = at
                                at += held
                            }
                            for id in from {
                                let bucket = Int(UInt32(bitPattern: edge[Int(id)]) >> shift & mask)
                                to[starts[bucket]] = id
                                starts[bucket] += 1
                            }
                        }
                    }
                }
                swap(&order, &scratch)
            }
        }
        return order
    }
}
