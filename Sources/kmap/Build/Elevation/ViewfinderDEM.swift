import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// Viewfinder Panoramas elevation tiles, fetched without pyhgtmap. Tiles come in zone-wide
/// zip archives, and which zone holds which degree is stated only by the image map on the
/// coverage page, so a fetch downloads a claiming archive, unpacks every `.hgt` in it and
/// corrects the index to what it held. The index file format and location are pyhgtmap's.
enum ViewfinderDEM {

    /// `view1` and `view3`: one and three arc-second.
    static func sourceID(_ resolution: Int) -> String { "view\(resolution)" }

    static func directoryName(_ resolution: Int) -> String { "VIEW\(resolution)" }

    static func cacheDirectory(_ resolution: Int) -> URL {
        Paths.hgtCache.appendingPathComponent(directoryName(resolution), isDirectory: true)
    }

    static func cachedTile(_ area: String, resolution: Int) -> URL {
        cacheDirectory(resolution).appendingPathComponent("\(area).hgt")
    }

    /// A `.hgt` is a bare grid of big-endian 16-bit samples, so its size is the only thing
    /// that says whether a download finished. 3601² at one arc-second, 1201² at three.
    static func expectedSize(_ resolution: Int) -> Int64 {
        let n = Int64(3600 / resolution + 1)
        return 2 * n * n
    }

    static func isComplete(_ url: URL, resolution: Int) -> Bool {
        FileTools.exists(url) && FileTools.size(of: url) == expectedSize(resolution)
    }

    static func indexFile(_ resolution: Int) -> URL {
        Paths.hgtCache.appendingPathComponent("viewfinderHgtIndex_\(resolution).txt")
    }

    /// The coverage page, over https: the site redirects from http, and a ranged download
    /// cannot follow a redirect.
    private static func coverageURL(_ resolution: Int) -> URL? {
        URL(string: "https://viewfinderpanoramas.org/Coverage%20map%20viewfinderpanoramas_org"
            + "\(resolution).htm")
    }

    /// pyhgtmap stamps a version into the index header and rebuilds when it does not match;
    /// matching its numbers keeps a shared cache from being rebuilt by either program.
    static func indexVersion(_ resolution: Int) -> Int { resolution == 1 ? 2 : 4 }

    // MARK: The index

    /// Which zip archive claims which degree tile.
    struct Index {
        /// Archive URL to the tile names it covers.
        var entries: [String: [String]] = [:]

        /// Archives that claim this tile, in a settled order so a failure is repeatable.
        func urls(for area: String) -> [String] {
            entries.filter { $0.value.contains(area) }.keys.sorted()
        }

        static func load(_ url: URL) -> Index? {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var index = Index()
            var current: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let row = line.trimmingCharacters(in: .whitespaces)
                if row.isEmpty || row.hasPrefix("#") { continue }
                if row.hasPrefix("["), row.hasSuffix("]") {
                    let url = String(row.dropFirst().dropLast())
                    current = url
                    if index.entries[url] == nil { index.entries[url] = [] }
                } else if let current {
                    index.entries[current, default: []].append(row)
                }
            }
            return index.entries.isEmpty ? nil : index
        }

        func save(to url: URL, resolution: Int) throws {
            var text = "# VIEW\(resolution) index file, VERSION=\(indexVersion(resolution))\n"
            for zip in entries.keys.sorted() {
                text += "[\(zip)]\n"
                for area in entries[zip] ?? [] { text += "\(area)\n" }
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Reads the coverage page's image map: every `<area>` carries the rectangle it
        /// stands for and the archive it links to.
        static func parse(coveragePage html: String) -> Index {
            var index = Index()
            // A tag at a time, so attribute order or a newline inside the tag does not
            // matter.
            for tag in html.allMatches("(?is)<area[^>]*>") {
                guard let coords = attribute("coords", in: tag),
                      let href = attribute("href", in: tag)?
                          .trimmingCharacters(in: .whitespaces),
                      !href.isEmpty else { continue }
                index.entries[href, default: []]
                    .append(contentsOf: innerAreas(coords).map { $0.uppercased() }.sorted())
            }
            return index
        }

        private static func attribute(_ name: String, in tag: String) -> String? {
            for pattern in ["(?i)\(name)\\s*=\\s*\"([^\"]*)\"",
                            "(?i)\(name)\\s*=\\s*'([^']*)'",
                            "(?i)\(name)\\s*=\\s*([^\\s>]+)"] {
                if let value = tag.firstCapture(pattern) { return value }
            }
            return nil
        }
    }

    /// The degree tiles inside one rectangle of the coverage image map, which is 1800×900
    /// pixels for 360°×180°, five pixels to the degree. The rounding and the southern
    /// hemisphere test follow pyhgtmap, so indexes written by either program agree.
    static func innerAreas(_ coords: String) -> [String] {
        let parts = coords.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return [] }
        let ratio = 1800.0 / 360.0
        let west = Int(Double(parts[0]) / ratio + 0.5) - 180
        let north = 90 - Int(Double(parts[1]) / ratio + 0.5)
        let east = Int(Double(parts[2]) / ratio + 0.5) - 180
        let south = 90 - Int(Double(parts[3]) / ratio + 0.5)
        var names: [String] = []
        for lon in west..<max(west, east) {
            for lat in south..<max(south, north) {
                let lonName = lon < 0 ? String(format: "W%03d", -lon)
                                      : String(format: "E%03d", lon)
                let latName = south < 0 ? String(format: "S%02d", -lat)
                                        : String(format: "N%02d", lat)
                names.append(latName + lonName)
            }
        }
        return names
    }

    // MARK: Fetching

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noIndex(Int)
        case notCovered(String)
        case notInAnyArchive(String)
        /// No unpacker on this machine can open a zip.
        case cannotUnpack(String)

        var description: String {
            switch self {
            case .noIndex(let resolution):
                "no coverage index for view\(resolution), and the coverage map could not be read"
            case .notCovered(let area):
                "\(area) is outside every Viewfinder zone"
            case .notInAnyArchive(let area):
                "\(area) is not in any of the archives that claim to cover it"
            case .cannotUnpack(let why):
                why
            }
        }
    }

    /// Loads the index, building it from the coverage page if there is none cached.
    static func index(_ resolution: Int, downloader: Downloader? = nil,
                      log: (String) -> Void) async throws -> Index {
        let file = indexFile(resolution)
        if let cached = Index.load(file) { return cached }

        guard let url = coverageURL(resolution) else { throw Trouble.noIndex(resolution) }
        log("building the Viewfinder coverage index for view\(resolution)")
        Paths.ensure(Paths.hgtCache)
        // One plain GET rather than the downloader, which needs a Content-Length to divide
        // into byte ranges; the server compresses this page, so there is none.
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { throw Trouble.noIndex(resolution) }
        // The page declares no dependable charset; latin-1 decodes any byte, and the bytes
        // that matter here are ASCII.
        //
        // `CodePage.latin1` rather than Foundation, which cannot be relied on for this off
        // Apple's platforms: measured, `String(data:encoding:.isoLatin1)` decodes a short
        // buffer on Linux and returns nil for one the size of this page — 40 kB — so every
        // Viewfinder download failed there, with contours and the DEM along with it.
        let html = CodePage.latin1(data)
        let built = Index.parse(coveragePage: html)
        guard !built.entries.isEmpty else { throw Trouble.noIndex(resolution) }
        try? built.save(to: file, resolution: resolution)
        log("indexed \(built.entries.count) Viewfinder archive(s) for view\(resolution)")
        return built
    }

    /// Fetches one degree tile, keeping the other tiles its archive carried, which are
    /// usually the neighbours asked for next.
    @discardableResult
    static func fetch(_ area: String, resolution: Int, index: inout Index,
                      downloader: Downloader, runner: ProcessRunner,
                      log: @escaping (String) -> Void) async throws -> URL {
        let destination = cachedTile(area, resolution: resolution)
        if isComplete(destination, resolution: resolution) { return destination }

        let directory = cacheDirectory(resolution)
        Paths.ensure(directory)
        let candidates = index.urls(for: area)
        guard !candidates.isEmpty else { throw Trouble.notCovered(area) }

        for zip in candidates {
            guard let url = URL(string: zip), url.scheme == "http" || url.scheme == "https"
            else { continue }
            let archive = directory
                .appendingPathComponent("download-\(UUID().uuidString.prefix(8)).zip")
            do {
                log("fetching \(url.lastPathComponent) for \(area)")
                _ = try await downloader.download(url: url, to: archive, connections: 4)
                let unpacked = try await unpack(archive, into: directory, runner: runner)
                FileTools.removeIfPresent(archive)
                // A zone that is mostly sea holds fewer tiles than its rectangle claims, so
                // the index is corrected to what the archive actually carried.
                if index.entries[zip]?.sorted() != unpacked.sorted() {
                    index.entries[zip] = unpacked.sorted()
                    try? index.save(to: indexFile(resolution), resolution: resolution)
                }
            } catch {
                FileTools.removeIfPresent(archive)
                log("\(url.lastPathComponent): \(error)")
                continue
            }
            if isComplete(destination, resolution: resolution) { return destination }
        }
        throw Trouble.notInAnyArchive(area)
    }

    /// Unpacks every `.hgt` in the archive flat: they sit in per-zone folders inside, and
    /// the rest of the pipeline expects them one directory deep.
    private static func unpack(_ archive: URL, into directory: URL,
                               runner: ProcessRunner) async throws -> [String] {
        let staging = directory
            .appendingPathComponent("unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }
        guard let unpacker = Archive.current else {
            throw Trouble.cannotUnpack(Archive.missingNote())
        }
        // Everything is unpacked and then walked: not every unpacker can flatten paths on
        // the way out, and the tiles are not always exactly one folder deep.
        let unpack = unpacker.unpack(archive, into: staging)
        _ = try await runner.run(unpack.executable, unpack.arguments,
                                 allowFailure: true) { _ in }
        var names: [String] = []
        for file in FileTools.allFiles(under: staging)
        where file.pathExtension.lowercased() == "hgt" {
            let name = file.deletingPathExtension().lastPathComponent.uppercased()
            let landing = directory.appendingPathComponent("\(name).hgt")
            FileTools.removeIfPresent(landing)
            try? FileManager.default.moveItem(at: file, to: landing)
            names.append(name)
        }
        return names
    }
}
