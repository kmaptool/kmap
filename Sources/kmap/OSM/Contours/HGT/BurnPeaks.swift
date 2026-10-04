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
        // Sorted, on everything a peak holds: the workers take blocks in any order.
        found.sort { ($0.lat, $0.lon, $0.name, $0.ele) < ($1.lat, $1.lon, $1.name, $1.ele) }
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
            try FileTools.write(Data(tile.samples), to: out.appendingPathComponent(name))
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

    static let metresPerFoot = 0.3048
    private static let feetSuffixes = ["feet", "ft", "'", "\u{2032}"]
    private static let metreSuffixes = ["metres", "meters", "m"]

    /// OSM `ele` as metres: `1527`, `1527.4`, `1527,4`, `1 527`, `1,527`, `1527 m`. Feet
    /// are converted where they are declared, `5000 ft`, `5000'`, `5000 feet`, and where
    /// nothing else fits: no summit stands 14,505 metres high, so that many is feet. Nil
    /// for anything else, or outside `range`. A wrong unit that fits is caught later, by
    /// the terrain: a height in feet read as metres is three times too high.
    static func metres(_ raw: String?) -> Double? {
        parse(raw, inFeet: false)
    }

    /// `ele:ft`, which some American summits carry instead of `ele`.
    static func metres(feet raw: String?) -> Double? {
        parse(raw, inFeet: true)
    }

    private static func parse(_ raw: String?, inFeet: Bool) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !text.isEmpty
        else { return nil }
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        text = text.replacingOccurrences(of: " ", with: "")
        var feet = inFeet
        if let suffix = feetSuffixes.first(where: { text.hasSuffix($0) }) {
            text = String(text.dropLast(suffix.count))
            feet = true
        } else if let suffix = metreSuffixes.first(where: { text.hasSuffix($0) }) {
            text = String(text.dropLast(suffix.count))
        }
        if text.contains(",") {
            // `1,527` and `1,527.4` group thousands; `1527,4` is a decimal comma.
            let grouped = text.contains(".") || groupsThousands(text)
            text = text.replacingOccurrences(of: ",", with: grouped ? "" : ".")
        }
        guard let value = Double(text) else { return nil }
        if !feet, value > range.upperBound, value * metresPerFoot <= range.upperBound {
            feet = true
        }
        let height = feet ? value * metresPerFoot : value
        return range.contains(height) ? height : nil
    }

    /// Whether every comma has exactly three digits after it, up to the next: `1,527`,
    /// `14,505`, but not `1527,4` or `1,5`.
    private static func groupsThousands(_ text: String) -> Bool {
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count > 1, let first = groups.first, (1...3).contains(first.count),
            first.allSatisfy(\.isNumber) || first.hasPrefix("-")
        else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    /// Every summit node with a usable height.
    private struct PeakScan: OSMSink {
        let wantedParts: OSMParts = .nodes

        var peaks: [Peak] = []

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            var natural: String?, ele: String?, eleFeet: String?, name = ""
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                switch block.text(Int(tags[at])) {
                case "natural": natural = block.text(Int(tags[at + 1]))
                case "ele": ele = block.text(Int(tags[at + 1]))
                case "ele:ft": eleFeet = block.text(Int(tags[at + 1]))
                case "name": name = block.text(Int(tags[at + 1]))
                default: break
                }
                at += 2
            }
            guard natural == "peak" || natural == "volcano",
                let height = BurnPeaks.metres(ele) ?? BurnPeaks.metres(feet: eleFeet)
            else { return }
            peaks.append(Peak(lat: lat, lon: lon, ele: height, name: name))
        }
    }
}
