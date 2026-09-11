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

    /// Every summit in the extracts, as one list.
    static func peaks(in urls: [URL]) throws -> [Peak] {
        var found: [Peak] = []
        for url in urls {
            for part in try PBFReader(url: url).readConcurrently(make: { PeakScan() }) {
                found.append(contentsOf: part.peaks)
            }
        }
        // Sorted: the workers finish in any order.
        found.sort { ($0.lat, $0.lon, $0.name) < ($1.lat, $1.lon, $1.name) }
        return found
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
        // One tile in memory at a time.
        for (key, summits) in byTile.sorted(by: { $0.key < $1.key }) {
            guard let path = available[key], tiles?.contains(key) ?? true else {
                report.outside += summits.count
                continue
            }
            let tile = try Tile(path)
            for peak in summits { burn(peak, into: tile, report: &report) }
            guard tile.dirty else { continue }
            let name = tile.path.lastPathComponent
            try Data(tile.samples).write(to: out.appendingPathComponent(name))
            report.written.append(name)
        }
        return report
    }

    private func burn(_ peak: Peak, into tile: Tile, report: inout Report) {
        guard let (row, column) = tile.index(peak.lat, peak.lon) else {
            report.outside += 1
            return
        }
        let current = tile.get(row, column)
        if current <= Self.void {
            report.rejected.append((peak.name, peak.ele, nil, "void"))
            return
        }
        let highest = tile.localMax(row, column, radius: radius, lat: peak.lat)
        guard let highest, abs(peak.ele - Double(highest)) <= threshold else {
            report.rejected.append((peak.name, peak.ele, highest, "disagrees with the terrain"))
            return
        }
        // Half a metre rounds up, not to the nearest even number.
        let target = Int(peak.ele.rounded(.toNearestOrAwayFromZero))
        let lifted = tile.raise(row, column, ring: Self.ring, to: target)
        guard lifted > 0 else {
            report.already += 1
            return
        }
        report.raised += 1
        report.cells += lifted
        if target > current { report.gains.append(target - current) }
    }

    /// OSM `ele` as metres: `1527`, `1527.4`, `1527 m`, `1 527`. Nil for feet or
    /// anything outside `range`.
    static func metres(_ raw: String?) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else { return nil }
        if text.contains("ft") || text.contains("'") || text.contains("feet") { return nil }
        text = text.replacingOccurrences(of: ",", with: ".")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        for suffix in [" metres", " meters", "metres", "meters", " m", "m"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        text = text.replacingOccurrences(of: " ", with: "")
        guard let value = Double(text), Self.range.contains(value) else { return nil }
        return value
    }

    /// Every summit node with a usable height.
    private struct PeakScan: OSMSink {
        let wantedParts: OSMParts = .nodes

        var peaks: [Peak] = []

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            var natural: String?, ele: String?, name = ""
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                switch block.text(Int(tags[at])) {
                case "natural": natural = block.text(Int(tags[at + 1]))
                case "ele": ele = block.text(Int(tags[at + 1]))
                case "name": name = block.text(Int(tags[at + 1]))
                default: break
                }
                at += 2
            }
            guard natural == "peak" || natural == "volcano",
                  let height = BurnPeaks.metres(ele) else { return }
            peaks.append(Peak(lat: lat, lon: lon, ele: height, name: name))
        }
    }

    /// One .hgt, held as its samples with its own grid size.
    private final class Tile {
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
            guard n * n * 2 == samples.count else {
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
            let row = Int(((Double(lat) + 1 - latitude) * Double(n - 1)).rounded())
            let column = Int(((longitude - Double(lon)) * Double(n - 1)).rounded())
            guard row >= 0, row < n, column >= 0, column < n else { return nil }
            return (row, column)
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
            var lifted = 0
            for r in max(0, row - ring)...min(n - 1, row + ring) {
                for c in max(0, column - ring)...min(n - 1, column + ring) {
                    let held = get(r, c)
                    guard held > BurnPeaks.void, held < value else { continue }
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
