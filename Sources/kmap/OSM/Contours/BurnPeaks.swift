import Foundation

/// Writes OSM summit heights into the .hgt tiles a build is about to contour.
///
/// A 30 m cell straddling a cliff averages the top of the face with the bottom, so the
/// cell holding a cliff-top summit reads low. An `ele` within `threshold` metres of the
/// highest cell within `radius` is written into the summit's own cell. Cells are only
/// ever raised, never lowered.
struct BurnPeaks {
    /// Below this a sample is a void, not ground.
    static let void = -500
    static let range = -500.0...9000.0

    var pbf: URL
    var hgt: URL
    var out: URL
    var threshold = 60.0
    var radius = 100.0

    struct Report {
        var peaks = 0
        var raised = 0
        var already = 0
        var rejected: [(name: String, ele: Double, terrain: Int?, why: String)] = []
        var outside = 0
        var written: [String] = []
        var gains: [Int] = []
    }

    /// A summit worth writing in: where it is and how high OSM says it is.
    struct Peak {
        var lat: Double
        var lon: Double
        var ele: Double
        var name: String
    }

    /// Every summit in the extract. Read once and handed to each elevation source in
    /// turn, since a build has several.
    static func peaks(in url: URL) throws -> [Peak] {
        var found: [Peak] = []
        for part in try PBFReader(url: url).readConcurrently(make: { PeakScan() }) {
            found.append(contentsOf: part.peaks)
        }
        // Sorted, so the report is the same from run to run whatever order the workers
        // finished in.
        found.sort { ($0.lat, $0.lon, $0.name) < ($1.lat, $1.lon, $1.name) }
        return found
    }

    func run() throws -> Report {
        try run(peaks: Self.peaks(in: pbf))
    }

    func run(peaks: [Peak]) throws -> Report {
        var available: [String: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: hgt.path)) ?? [] {
            guard name.lowercased().hasSuffix(".hgt"), name.count >= 7 else { continue }
            available[String(name.prefix(7)).uppercased()] = hgt.appendingPathComponent(name)
        }

        var report = Report()
        report.peaks = peaks.count
        var tiles: [String: Tile] = [:]

        for peak in peaks {
            let key = HGTName.of(lat: peak.lat, lon: peak.lon)
            guard let path = available[key] else {
                report.outside += 1
                continue
            }
            let tile: Tile
            if let held = tiles[key] {
                tile = held
            } else {
                tile = try Tile(path)
                tiles[key] = tile
            }
            guard let (row, column) = tile.index(peak.lat, peak.lon) else {
                report.outside += 1
                continue
            }
            let current = tile.get(row, column)
            if current <= Self.void {
                report.rejected.append((peak.name, peak.ele, nil, "void"))
                continue
            }
            guard let highest = tile.localMax(row, column, radius: radius, lat: peak.lat),
                  abs(peak.ele - Double(highest)) <= threshold else {
                report.rejected.append((peak.name, peak.ele,
                                        tile.localMax(row, column, radius: radius, lat: peak.lat),
                                        "disagrees with the terrain"))
                continue
            }
            // Half a metre rounds up, not to the nearest even number as Python's round()
            // does.
            let target = Int(peak.ele.rounded(.toNearestOrAwayFromZero))
            if target <= current {
                report.already += 1
                continue
            }
            tile.set(row, column, target)
            report.raised += 1
            report.gains.append(target - current)
        }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for key in tiles.keys.sorted() {
            guard let tile = tiles[key], tile.dirty else { continue }
            let name = tile.path.lastPathComponent
            try Data(tile.samples).write(to: out.appendingPathComponent(name))
            report.written.append(name)
        }
        return report
    }

    /// OSM `ele` as metres, or nil where it cannot be trusted.
    ///
    /// Accepts `1527`, `1527.4`, `1527 m`, `1 527`; refuses anything carrying a foot
    /// marker, and anything outside `range`.
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

        /// Highest ground within the radius, clipped at the tile edge.
        ///
        /// The window is clipped rather than continued into the neighbouring tile; a
        /// clipped window can only lower the maximum.
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
