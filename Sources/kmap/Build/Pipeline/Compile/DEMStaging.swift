import Foundation

/// The elevation cells staged for mkgmap's DEM layer.
extension BuildPipeline {
    /// `--dem=` for mkgmap run in `cwd`, the paths relative to it: mkgmap splits the value
    /// on commas, and a work folder chosen by the user may have one in its name.
    static func demOption(_ cells: [URL], runIn cwd: URL) -> String {
        "--dem=" + cells.map { relativePath(of: $0, from: cwd) }.joined(separator: ",")
    }

    /// `url` as reached from `base`, with `..` steps; the full path where they share no root.
    static func relativePath(of url: URL, from base: URL) -> String {
        let to = url.standardizedFileURL.pathComponents
        let from = base.standardizedFileURL.pathComponents
        let shared = zip(to, from).prefix { $0 == $1 }.count
        // A root alone shared, as 2 Windows drives have, is no way between them.
        guard shared > 1 else { return url.path }
        let steps = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared)
        return steps.isEmpty ? "." : steps.joined(separator: "/")
    }

    /// One directory holding exactly the elevation cells inside the regions' outlines, so
    /// mkgmap shades no ground the map does not cover. Each cell is linked, or copied, from
    /// the first `demSearchPaths()` directory holding it, so burned copies shadow originals.
    func stageDEMCells() -> [URL] {  // internal for DEMStagingTests
        let ranked = demSearchPaths()
        guard !ranked.isEmpty else { return [] }
        let staged = recipe.workDirectory.appendingPathComponent("dem-cells", isDirectory: true)
        FileTools.removeIfPresent(staged)
        Paths.ensure(staged)
        var linked = 0
        var lost: [String] = []
        for cell in elevationCells() {
            let name = HGTName.of(lat: cell.lat, lon: cell.lon) + ".hgt"
            guard
                let found = ranked.first(where: {
                    FileTools.exists($0.appendingPathComponent(name))
                })
            else { continue }
            let source = found.appendingPathComponent(name)
            let link = staged.appendingPathComponent(name)
            // Counted only once the cell reads through it: without the symlink privilege on
            // Windows every link fails, and a link from a network drive to a local one is
            // not followed there. An empty --dem path yields flat relief.
            if (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)) != nil,
                Self.reads(link)
            {
                linked += 1
                continue
            }
            FileTools.removeIfPresent(link)
            if (try? FileTools.copy(source, to: link)) != nil {
                linked += 1
            } else {
                // A cell cut short would be read at another resolution.
                FileTools.removeIfPresent(link)
                lost.append(name)
            }
        }
        if !lost.isEmpty {
            log.warn(
                "\(lost.count) elevation cell(s) could not be staged, so their relief is flat: \(lost.joined(separator: ", "))"
            )
        }
        guard linked > 0 else { return [] }
        return [staged]
    }

    /// The elevation sources the map's cells come from, best first: for each cell the
    /// first `demSearchPaths()` directory holding it, as the staging and the contours take
    /// it. A burned copy counts as its original.
    func demSourcesUsed() -> [String] {
        let ranked = demSearchPaths()
        var serving = Set<Int>()
        for cell in elevationCells() {
            let name = HGTName.of(lat: cell.lat, lon: cell.lon) + ".hgt"
            if let index = ranked.firstIndex(where: { FileTools.exists($0.appendingPathComponent(name)) }) {
                serving.insert(index)
            }
        }
        var used: [String] = []
        for index in serving.sorted() {
            let id = Self.demSourceID(directory: ranked[index].lastPathComponent)
            if !used.contains(id) { used.append(id) }
        }
        return used
    }

    /// The source id of a cache directory: COP1 is copernicus1, VIEW3 is view3.
    static func demSourceID(directory: String) -> String {
        let name = directory.lowercased()
        return DEMSources.all.first { $0.directoryName.lowercased() == name }?.sourceID ?? name
    }

    /// Whether a file opens for reading, through whatever link leads to it.
    static func reads(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}
