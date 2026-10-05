import Foundation

extension HGTConversion {
    /// The tiles available to sample from, opened as they are wanted and then kept.
    /// Asked from every lane of a conversion. `@unchecked Sendable` stands on `lock`: the
    /// open tiles and the absent set are reached only under it.
    final class Mosaic: @unchecked Sendable {
        private var open: [Int: GeoTIFF] = [:]
        private var absent: Set<Int> = []
        /// Files that are there and would not open, by cell.
        private var failures: [Int: Error] = [:]
        /// Cells written and released.
        private var released: Set<Int> = []
        private let locate: (Int, Int) -> URL?
        private let lock = NSLock()

        /// - Parameter locate: the file holding the degree cell, if there is one. A cell
        ///   that is entirely sea has no file, which is not an error.
        init(locate: @escaping (Int, Int) -> URL?) {
            self.locate = locate
        }

        /// The 9 cells a node of this one can be answered from: its own, and the
        /// neighbours the southern row, the eastern column and the corner belong to.
        private static let neighbourhood = [
            (0, 0), (-1, 0), (0, 1), (-1, 1),
            (0, -1), (-1, -1), (1, 0), (1, 1), (1, -1)
        ]

        /// A cell as a number: asked once per node on the slow path, where a name costs. East
        /// of 179 is -180: the cell across the antimeridian.
        private static func key(lat: Int, lon: Int) -> Int { lat * 1000 + wrapped(lon) }

        private static func wrapped(_ lon: Int) -> Int {
            lon >= 180 ? lon - 360 : lon < -180 ? lon + 360 : lon
        }

        /// Whether anything at all covers this cell or the neighbours it borrows from.
        /// Asked once before the grid is filled, so a cell nothing covers is refused
        /// before every node is tried against 9 neighbours under the lock.
        func covers(cellLat: Int, cellLon: Int) -> Bool {
            Self.neighbourhood.contains { tile(lat: cellLat + $0.0, lon: cellLon + $0.1) != nil }
        }

        /// Lets the cell's own file forget its decoded tiles. A neighbour still to come
        /// decodes the edge it borrows again, which is far cheaper than keeping every
        /// cell of a large region decoded until the pass ends.
        ///
        /// A neighbour already released has decoded its edge again for this cell; it forgets
        /// that too once every cell that borrows from it, among those with a file, is done.
        func release(cellLat: Int, cellLon: Int) {
            var done: [GeoTIFF] = []
            lock.lock()
            released.insert(Self.key(lat: cellLat, lon: cellLon))
            if let own = open[Self.key(lat: cellLat, lon: cellLon)] { done.append(own) }
            for (dLat, dLon) in Self.neighbourhood where dLat != 0 || dLon != 0 {
                let lat = cellLat + dLat, lon = cellLon + dLon
                guard let tiff = open[Self.key(lat: lat, lon: lon)], released.contains(Self.key(lat: lat, lon: lon))
                else { continue }
                let waiting = Self.neighbourhood.contains { borrower in
                    let (bLat, bLon) = (lat + borrower.0, lon + borrower.1)
                    let key = Self.key(lat: bLat, lon: bLon)
                    guard !released.contains(key), !absent.contains(key) else { return false }
                    return open[key] != nil || locate(bLat, Self.wrapped(bLon)) != nil
                }
                if !waiting { done.append(tiff) }
            }
            lock.unlock()
            for tiff in done { tiff.dropDecoded() }
        }

        /// Why the cell's file would not open, where it is there and did not.
        func failure(lat: Int, lon: Int) -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return failures[Self.key(lat: lat, lon: lon)]
        }

        func tile(lat: Int, lon: Int) -> GeoTIFF? {
            let key = Self.key(lat: lat, lon: lon)
            lock.lock()
            defer { lock.unlock() }
            if let hit = open[key] { return hit }
            if absent.contains(key) { return nil }
            guard let url = locate(lat, Self.wrapped(lon)) else {
                absent.insert(key)
                return nil
            }
            do {
                let tiff = try GeoTIFF(contentsOf: url)
                open[key] = tiff
                return tiff
            } catch {
                absent.insert(key)
                failures[key] = error
                return nil
            }
        }

        // MARK: A row at a time

        /// Where each node of an output row falls on a source row: the sample to its
        /// west, and how far past it the node is, in the lattice's unit. The same for
        /// every row of a tile, so it is worked out for the first and kept.
        struct RowPlan {
            fileprivate let originLon: Int, stepLon: Int, cellLon: Int, step: Int
            /// -1 where the node lies west of the tile.
            fileprivate var west: [Int]
            fileprivate var past: [Double]

            fileprivate init(originLon: Int, stepLon: Int, cellLon: Int, step: Int, width n: Int) {
                self.originLon = originLon
                self.stepLon = stepLon
                self.cellLon = cellLon
                self.step = step
                west = [Int](repeating: -1, count: n)
                past = [Double](repeating: 0, count: n)
                for column in 0..<n {
                    let east =
                        (cellLon * HGTConversion.arcSecondsPerDegree + column * step)
                        * HGTConversion.latticePerArcSecond - originLon
                    guard east >= 0 else { continue }
                    let x0 = Mosaic.floorDiv(east, stepLon)
                    west[column] = x0
                    past[column] = Double(east - x0 * stepLon)
                }
            }

            fileprivate func serves(originLon: Int, stepLon: Int, cellLon: Int, step: Int, width n: Int) -> Bool {
                self.originLon == originLon && self.stepLon == stepLon && self.cellLon == cellLon
                    && self.step == step && west.count == n
            }
        }

        /// A whole output row at once into `out`, which has room for `n` heights, or
        /// false if no single tile carries it. A node with nothing under it is NaN.
        ///
        /// Latitude is sampled once an arc-second everywhere, so the source row is read once
        /// and interpolated along. `step` is the output grid's spacing in arc-seconds: 1 for
        /// a 3601-node cell, 3 for a 1201-node one; a source of another step is refused.
        func row(
            cellLat: Int,
            cellLon: Int,
            row: Int,
            width n: Int,
            step: Int = 1,
            plan: inout RowPlan?,
            into out: UnsafeMutablePointer<Double>
        ) -> Bool {
            let lat =
                ((cellLat + 1) * HGTConversion.arcSecondsPerDegree - row * step)
                * HGTConversion.latticePerArcSecond
            // The row belongs to this cell unless it is the southern edge, which is the
            // first row of the cell below.
            let owner = row < n - 1 ? cellLat : cellLat - 1
            guard let tiff = tile(lat: owner, lon: cellLon), let grid = lattice(of: tiff),
                grid.stepLat == step * HGTConversion.latticePerArcSecond,
                let source = samples(of: tiff, grid: grid, at: lat)
            else { return false }

            // The tile to the east, for nodes past this one's last sample.
            var beyond: [Float] = []
            let neighbour = tile(
                lat: owner,
                lon: Self.floorDiv(grid.originLon, HGTConversion.latticePerDegree) + 1
            )
            if let neighbour, let far = lattice(of: neighbour), far.stepLon == grid.stepLon,
                far.stepLat == grid.stepLat
            {
                beyond = samples(of: neighbour, grid: far, at: lat) ?? []
            }

            if plan?.serves(originLon: grid.originLon, stepLon: grid.stepLon, cellLon: cellLon, step: step, width: n)
                != true
            {
                plan = RowPlan(
                    originLon: grid.originLon,
                    stepLon: grid.stepLon,
                    cellLon: cellLon,
                    step: step,
                    width: n
                )
            }
            guard let plan else { return false }
            let stepLon = Double(grid.stepLon)
            source.withUnsafeBufferPointer { near in
                beyond.withUnsafeBufferPointer { far in
                    plan.west.withUnsafeBufferPointer { west in
                        plan.past.withUnsafeBufferPointer { past in
                            let nearCount = near.count, total = near.count + far.count
                            @inline(__always)
                            func at(_ x: Int) -> Double {
                                if x < nearCount { return Double(near[x]) }
                                return x < total ? Double(far[x - nearCount]) : .nan
                            }
                            for column in 0..<n {
                                let x = west[column]
                                guard x >= 0 else {
                                    out[column] = .nan
                                    continue
                                }
                                let left = at(x)
                                let over = past[column]
                                out[column] = over == 0 ? left : left + (at(x + 1) - left) * over / stepLon
                            }
                        }
                    }
                }
            }
            return true
        }

        /// The tile's row lying on latitude `lat`, in the lattice's unit; nil if none does.
        private func samples(of tiff: GeoTIFF, grid: Lattice, at lat: Int) -> [Float]? {
            let south = grid.originLat - lat
            guard south >= 0, south % grid.stepLat == 0, south / grid.stepLat < tiff.height else { return nil }
            return try? tiff.row(south / grid.stepLat)
        }

        // MARK: A node at a time

        /// The height at 1 node of the output grid, bilinear between the samples around it.
        ///
        /// The node is named by whole numbers: which degree cell, and which of its 3601 rows
        /// and columns, never by latitude and longitude. Sources publish on whole
        /// arc-seconds, which integers name exactly and degrees round.
        func height(cellLat: Int, cellLon: Int, row: Int, column: Int) -> Double? {
            for (dLat, dLon) in Self.neighbourhood {
                guard let tiff = tile(lat: cellLat + dLat, lon: cellLon + dLon) else { continue }
                if let value = sample(tiff, cellLat: cellLat, cellLon: cellLon, row: row, column: column) {
                    return value
                }
            }
            return nil
        }

        /// Where a node sits inside 1 tile, and the height there.
        ///
        /// Past 50 deg of latitude Copernicus thins longitude sampling to 2400 samples a
        /// degree, a step of 1.5 seconds that whole arc-seconds cannot name: hence the
        /// lattice.
        private func sample(_ tiff: GeoTIFF, cellLat: Int, cellLon: Int, row: Int, column: Int) -> Double? {
            guard let grid = lattice(of: tiff) else { return nil }
            let lon =
                (cellLon * HGTConversion.arcSecondsPerDegree + column)
                * HGTConversion.latticePerArcSecond
            let lat =
                ((cellLat + 1) * HGTConversion.arcSecondsPerDegree - row)
                * HGTConversion.latticePerArcSecond

            var east = lon - grid.originLon
            // A tile across the antimeridian is a whole turn away.
            if east >= 360 * HGTConversion.latticePerDegree { east -= 360 * HGTConversion.latticePerDegree }
            let south = grid.originLat - lat
            guard east >= 0, south >= 0 else { return nil }
            let x0 = Self.floorDiv(east, grid.stepLon)
            let y0 = Self.floorDiv(south, grid.stepLat)
            let fx = Double(east - x0 * grid.stepLon) / Double(grid.stepLon)
            let fy = Double(south - y0 * grid.stepLat) / Double(grid.stepLat)
            guard x0 >= 0, y0 >= 0, x0 < tiff.width, y0 < tiff.height else { return nil }

            func stored(_ tiff: GeoTIFF, _ x: Int, _ y: Int) -> Double? {
                (try? tiff.value(row: y, column: x)).flatMap { $0.map(Double.init) }
            }
            // Straight onto a sample, which is where most nodes land.
            if fx == 0, fy == 0 { return stored(tiff, x0, y0) }

            // The right-hand samples may be the next tile's first column: a thinned tile's
            // last node sits halfway to the next degree. East and west share 1 lattice.
            func value(_ x: Int, _ y: Int) -> Double? {
                guard y >= 0, y < tiff.height else { return nil }
                if x < tiff.width { return stored(tiff, x, y) }
                // The neighbour east of this tile, which on the southernmost row is not
                // the neighbour east of the cell being written: that row comes from below.
                let here = (
                    lat: Self.floorDiv(grid.originLat, HGTConversion.latticePerDegree) - 1,
                    lon: Self.floorDiv(grid.originLon, HGTConversion.latticePerDegree)
                )
                guard let next = tile(lat: here.lat, lon: here.lon + 1),
                    let far = lattice(of: next), far.stepLon == grid.stepLon,
                    x - tiff.width < next.width
                else { return nil }
                return stored(next, x - tiff.width, y)
            }

            guard let topLeft = value(x0, y0) else { return nil }
            if fx == 0 {
                guard let bottomLeft = value(x0, y0 + 1) else { return topLeft }
                return topLeft + (bottomLeft - topLeft) * fy
            }
            guard let topRight = value(x0 + 1, y0) else { return nil }
            let top = topLeft + (topRight - topLeft) * fx
            if fy == 0 { return top }
            guard let bottomLeft = value(x0, y0 + 1),
                let bottomRight = value(x0 + 1, y0 + 1)
            else { return top }
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
            return top + (bottom - top) * fy
        }

        // MARK: The lattice

        /// A tile's grid in thousandths of an arc-second, counted from the equator and
        /// the prime meridian.
        private struct Lattice {
            let originLon: Int, originLat: Int, stepLon: Int, stepLat: Int
        }

        /// How far a tile's own figures may be from the lattice and still be on it.
        private static let latticeTolerance = 1e-3

        /// Nil unless the tile is aligned to the lattice on a step of at least 1 unit:
        /// anything else is refused rather than guessed at.
        private func lattice(of tiff: GeoTIFF) -> Lattice? {
            let unit = Double(HGTConversion.latticePerDegree)
            func whole(_ degrees: Double) -> Int? {
                let units = (degrees * unit).rounded()
                return abs(degrees * unit - units) < Self.latticeTolerance ? Int(units) : nil
            }
            guard let stepLon = whole(tiff.stepLon), stepLon >= 1,
                let stepLat = whole(-tiff.stepLat), stepLat >= 1,
                let originLon = whole(tiff.originLon), let originLat = whole(tiff.originLat)
            else { return nil }
            return Lattice(originLon: originLon, originLat: originLat, stepLon: stepLon, stepLat: stepLat)
        }

        fileprivate static func floorDiv(_ a: Int, _ b: Int) -> Int {
            let q = a / b
            return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
        }
    }
}
