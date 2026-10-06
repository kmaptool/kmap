import Foundation

/// Writes OSM summit heights into the .hgt tiles the DEM layer is built from.
///
/// The cell under a summit reads below it, and the receiver interpolates the DEM around
/// the node. So the node's cell and the ring around it are raised to `ele`, only ever up,
/// and only when `ele` agrees with the highest ground nearby.
struct BurnPeaks {
    /// Below this a sample is a void, not ground.
    static let void = -500
    static let range = -500.0...9000.0
    /// Cells raised each side of the summit's cell: the reach of any interpolation at the node.
    static let ring = 1

    /// The extracts the summits come from: one per region of the build.
    var extracts: [URL]
    var hgt: URL
    var out: URL
    /// How far `ele` may differ from the highest ground within `radius` metres.
    var threshold = 60.0
    var radius = 100.0
    /// Asked between tiles: the burn runs on a thread of its own.
    var shouldStop: () -> Bool = { false }
    /// Tiles to write, by name; nil for every tile holding a summit.
    var tiles: Set<String>?

    struct Report {
        var peaks = 0
        /// Summits that raised at least one cell, and the cells they raised.
        var raised = 0
        var cells = 0
        var already = 0
        var rejected: [(name: String, ele: Double, terrain: Int?, why: String)] = []
        /// Summits on a tile this run does not write.
        var outside = 0
        var written: [String] = []
        /// How far each summit's own cell was raised.
        var gains: [Int] = []
    }

    /// Where a summit is and how high OSM says it is.
    struct Peak {
        var lat: Double
        var lon: Double
        var ele: Double
        var name: String
    }

    func run() throws -> Report {
        try run(peaks: Self.peaks(in: extracts))
    }

    func run(peaks: [Peak]) throws -> Report {
        var available: [String: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: hgt.path)) ?? [] {
            guard name.lowercased().hasSuffix(".hgt"), name.count >= 7 else { continue }
            available[String(name.prefix(7)).uppercased()] = hgt.appendingPathComponent(name)
        }
        var byTile: [String: [Peak]] = [:]
        for peak in peaks {
            byTile[HGTName.of(lat: peak.lat, lon: peak.lon), default: []].append(peak)
        }

        var report = Report()
        report.peaks = peaks.count
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A summit within the ring of its tile's edge raises the neighbour's side of it too:
        // 2 tiles share their edge row, and each traces its own contours.
        var spill: [String: [(peak: Peak, target: Int)]] = [:]
        // One tile in memory at a time.
        for (key, summits) in byTile.sorted(by: { $0.key < $1.key }) {
            if shouldStop() { throw CancellationError() }
            guard let path = available[key], tiles?.contains(key) ?? true else {
                report.outside += summits.count
                continue
            }
            let tile = try Tile(path)
            for peak in summits {
                guard let target = burn(peak, into: tile, report: &report),
                    let (row, column) = tile.index(peak.lat, peak.lon)
                else { continue }
                // Only the neighbours whose edge the ring reaches: row 0 is the north tile's
                // last row, and so on round.
                let edge = tile.n - 1 - Self.ring
                let north = row <= Self.ring, south = row >= edge
                let west = column <= Self.ring, east = column >= edge
                for dLat in -1...1 where dLat == 0 || (dLat == 1 ? north : south) {
                    for dLon in -1...1 where (dLat != 0 || dLon != 0) && (dLon == 0 || (dLon == 1 ? east : west)) {
                        var lon = tile.lon + dLon
                        if lon > 179 { lon -= 360 } else if lon < -180 { lon += 360 }
                        let neighbour = HGTName.of(lat: tile.lat + dLat, lon: lon)
                        spill[neighbour, default: []].append((peak, target))
                    }
                }
            }
            guard tile.dirty else { continue }
            try keep(tile, in: &report)
        }
        for (key, raised) in spill.sorted(by: { $0.key < $1.key }) {
            if shouldStop() { throw CancellationError() }
            guard let path = available[key], tiles?.contains(key) ?? true else { continue }
            // Written already this run, with its own summits raised: that copy is the one.
            let written = out.appendingPathComponent(path.lastPathComponent)
            let tile = try Tile(report.written.contains(path.lastPathComponent) ? written : path)
            for (peak, target) in raised {
                let (row, column) = tile.place(peak.lat, peak.lon)
                report.cells += tile.raise(row, column, ring: Self.ring, to: target)
            }
            guard tile.dirty else { continue }
            try keep(tile, in: &report)
        }
        return report
    }

    private func keep(_ tile: Tile, in report: inout Report) throws {
        let name = tile.path.lastPathComponent
        try FileTools.write(Data(tile.samples), to: out.appendingPathComponent(name))
        if !report.written.contains(name) { report.written.append(name) }
    }

    /// Burns 1 summit into its own tile. Returns the height it stands at, nil where it
    /// was refused or fell outside.
    @discardableResult
    private func burn(_ peak: Peak, into tile: Tile, report: inout Report) -> Int? {
        guard let (row, column) = tile.index(peak.lat, peak.lon) else {
            report.outside += 1
            return nil
        }
        let current = tile.get(row, column)
        if current <= Self.void {
            report.rejected.append((peak.name, peak.ele, nil, "void"))
            return nil
        }
        // A summit whose own cell is the sea is misplaced, not a peak the DEM missed.
        if current == 0 {
            report.rejected.append((peak.name, peak.ele, nil, "at sea level"))
            return nil
        }
        let highest = tile.localMax(row, column, radius: radius, lat: peak.lat)
        guard let highest, abs(peak.ele - Double(highest)) <= threshold else {
            report.rejected.append((peak.name, peak.ele, highest, "disagrees with the terrain"))
            return nil
        }
        // Half a metre rounds up, not to the nearest even number.
        let target = Int(peak.ele.rounded(.toNearestOrAwayFromZero))
        let lifted = tile.raise(row, column, ring: Self.ring, to: target)
        guard lifted > 0 else {
            report.already += 1
            return target
        }
        report.raised += 1
        report.cells += lifted
        if target > current { report.gains.append(target - current) }
        return target
    }
}
