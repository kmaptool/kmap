import Foundation

/// Structural checks on a finished map, so a problem is caught here rather than on the
/// device. Everything reported is read straight out of the container — no guesses.
enum MapVerifier {

    struct Finding {
        enum Level { case ok, warn, fail }
        let level: Level
        let label: String
        let detail: String
    }

    struct Report {
        let url: URL
        var findings: [Finding] = []
        var failed: Bool { findings.contains { $0.level == .fail } }
        var warned: Bool { findings.contains { $0.level == .warn } }
    }

    static func verify(_ url: URL) -> Report {
        var report = Report(url: url)

        guard FileTools.exists(url) else {
            report.findings.append(Finding(level: .fail, label: "file", detail: "not found"))
            return report
        }
        guard ImgContainer.isImg(url) else {
            report.findings.append(Finding(level: .fail, label: "container",
                                           detail: "not a Garmin IMG — no DSKIMG signature"))
            return report
        }

        let directory = ImgContainer.directory(of: url)
        report.findings.append(Finding(level: .ok, label: "container",
                                       detail: "\(directory.count) sub-file(s), \(Fmt.bytes(FileTools.size(of: url)))"))

        // Map tiles: every one needs TRE + RGN + LBL to draw at all.
        var tiles: Set<String> = []
        var extensions: [String: Set<String>] = [:]
        for sub in directory {
            let ext = sub.ext.uppercased()
            guard ["TRE", "RGN", "LBL", "NET", "NOD", "DEM"].contains(ext) else { continue }
            tiles.insert(sub.name)
            extensions[sub.name, default: []].insert(ext)
        }

        if let coverage = coverageFinding(of: url) { report.findings.append(coverage) }
        report.findings.append(tileFinding(tiles, extensions: extensions))
        report.findings.append(routingFinding(tiles, extensions: extensions))
        report.findings.append(demFinding(tiles, extensions: extensions))
        report.findings.append(indexFinding(directory))
        report.findings.append(typFinding(of: url, tiles: tiles))
        return report
    }

    /// A spot inside the map's own box that belongs to no tile draws as blank paper:
    /// the tile is what carries the sea fill and the DEM.
    private static func coverageFinding(of url: URL) -> Finding? {
        guard let coverage = MapCoverage.check(MapCoverage.tiles(in: url)) else { return nil }
        guard !coverage.holes.isEmpty else {
            return Finding(
                level: .ok, label: "coverage",
                detail: t("%d tile(s) cover their own box, %d sample(s) checked",
                          coverage.tiles.count, coverage.sampled))
        }
        let first = coverage.holes.prefix(3)
            .map { String(format: "%.2f %.2f", $0.lat, $0.lon) }
            .joined(separator: ", ")
        return Finding(
            level: .fail, label: "coverage",
            detail: t("%d of %d sample(s) fall in no tile — blank ground at %@",
                      coverage.holes.count, coverage.sampled, first))
    }

    /// Every tile needs TRE + RGN + LBL to draw at all.
    private static func tileFinding(_ tiles: Set<String>,
                                    extensions: [String: Set<String>]) -> Finding {
        guard !tiles.isEmpty else {
            return Finding(level: .fail, label: "tiles",
                           detail: "no map tiles — this map draws nothing")
        }
        let incomplete = tiles.filter { !(extensions[$0]?.isSuperset(of: ["TRE", "RGN", "LBL"]) ?? false) }
        guard !incomplete.isEmpty else {
            return Finding(level: .ok, label: "tiles",
                           detail: "\(tiles.count), all with TRE/RGN/LBL")
        }
        return Finding(level: .fail, label: "tiles",
                       detail: "\(incomplete.count) of \(tiles.count) incomplete: "
                             + incomplete.sorted().prefix(4).joined(separator: ", "))
    }

    private static func routingFinding(_ tiles: Set<String>,
                                       extensions: [String: Set<String>]) -> Finding {
        let routable = tiles.filter { extensions[$0]?.contains("NET") == true && extensions[$0]?.contains("NOD") == true }
        return Finding(
            level: routable.isEmpty ? .warn : .ok,
            label: "routing",
            detail: routable.isEmpty
                ? "no NET/NOD — the map cannot navigate, only display"
                : "\(routable.count)/\(tiles.count) tile(s) routable")
    }

    private static func demFinding(_ tiles: Set<String>,
                                   extensions: [String: Set<String>]) -> Finding {
        let withDEM = tiles.filter { extensions[$0]?.contains("DEM") == true }
        return Finding(
            level: withDEM.isEmpty ? .warn : .ok,
            label: "DEM layer",
            detail: withDEM.isEmpty
                ? "absent — no shaded relief or elevation profile"
                : "\(withDEM.count)/\(tiles.count) tile(s)")
    }

    private static func indexFinding(_ directory: [ImgContainer.SubFile]) -> Finding {
        guard let mdr = directory.first(where: { $0.ext.uppercased() == "MDR" }) else {
            return Finding(level: .warn, label: "search index",
                           detail: "no MDR — addresses and POIs are not searchable")
        }
        // The SRT carries the sort order the index is searched under; without it the
        // device misfiles non-Latin names.
        let hasSRT = directory.contains { $0.ext.uppercased() == "SRT" }
        return Finding(
            level: hasSRT ? .ok : .warn,
            label: "search index",
            detail: "MDR \(Fmt.bytes(Int64(mdr.size)))"
                  + (hasSRT ? " + SRT" : ", but no SRT — sorting may misfile names")
                  + " — on the device: Where To? > Addresses / POIs")
    }

    /// The TYP, and whether the device will actually apply it.
    private static func typFinding(of url: URL, tiles: Set<String>) -> Finding {
        guard let identity = ImgContainer.typIdentity(in: url) else {
            return Finding(
                level: .warn, label: "TYP",
                detail: "none embedded — the device picks its own colours")
        }
        let mapFamily = tiles.compactMap { Int($0.prefix(4)) }.first
        if let mapFamily, mapFamily != identity.familyID {
            return Finding(
                level: .fail, label: "TYP",
                detail: "family \(identity.familyID) but tiles are numbered for family "
                      + "\(mapFamily) — the device will ignore the TYP")
        }
        return Finding(
            level: .ok, label: "TYP",
            detail: "family \(identity.familyID), \(Fmt.bytes(Int64(identity.size)))")
    }
}
