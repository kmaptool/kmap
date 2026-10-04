import Foundation

// MARK: The coverage index

extension ViewfinderDEM {
    static func indexFile(_ resolution: Int) -> URL {
        Paths.hgtCache.appendingPathComponent("viewfinderHgtIndex_\(resolution).txt")
    }

    /// pyhgtmap stamps a version into the index header and rebuilds when it does not match;
    /// matching its numbers keeps a shared cache from being rebuilt by either program.
    static func indexVersion(_ resolution: Int) -> Int { resolution == 1 ? 2 : 4 }

    /// The coverage page, over https: the site redirects from http, and a ranged download
    /// cannot follow a redirect.
    private static func coverageURL(_ resolution: Int) -> URL? {
        URL(string: "https://viewfinderpanoramas.org/Coverage%20map%20viewfinderpanoramas_org\(resolution).htm")
    }

    private static let coverageTimeout: TimeInterval = 60

    /// Which zip archive claims which degree tile.
    struct Index {
        /// Archive URL to the tile names it covers.
        var entries: [String: [String]] = [:]

        /// Archives that claim this tile, in a settled order so a failure is repeatable.
        func urls(for area: String) -> [String] {
            entries.filter { $0.value.contains(area) }.keys.sorted()
        }

        /// An archive URL in brackets, then its tiles a line each. Nil for no archives.
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
            var text = "# \(directoryName(resolution)) index file, VERSION=\(indexVersion(resolution))\n"
            for zip in entries.keys.sorted() {
                text += "[\(zip)]\n"
                for area in entries[zip] ?? [] { text += "\(area)\n" }
            }
            try FileTools.write(text, to: url)
        }

        /// Reads the coverage page's image map: every `<area>` carries the rectangle it
        /// stands for and the archive it links to.
        static func parse(coveragePage html: String) -> Index {
            var index = Index()
            // A tag at a time, so attribute order or a newline inside the tag does not matter.
            for tag in html.allMatches("(?is)<area[^>]*>") {
                guard let coords = attribute("coords", in: tag),
                    let href = attribute("href", in: tag)?.trimmingCharacters(in: .whitespaces),
                    !href.isEmpty
                else { continue }
                index.entries[href, default: []]
                    .append(contentsOf: innerAreas(coords).map { $0.uppercased() }.sorted())
            }
            return index
        }

        /// An attribute's value: in double quotes, in single quotes, or bare.
        private static func attribute(_ name: String, in tag: String) -> String? {
            for pattern in [
                "(?i)\(name)\\s*=\\s*\"([^\"]*)\"",
                "(?i)\(name)\\s*=\\s*'([^']*)'",
                "(?i)\(name)\\s*=\\s*([^\\s>]+)"
            ] {
                if let value = tag.firstCapture(pattern) { return value }
            }
            return nil
        }
    }

    /// Pixels to the degree on the coverage image map: 1800 x 900 for 360 x 180 deg.
    private static let pixelsPerDegree = 5.0

    /// The degree tiles inside 1 rectangle of the coverage image map. The rounding and the
    /// southern hemisphere test follow pyhgtmap, so indexes written by either program agree.
    static func innerAreas(_ coords: String) -> [String] {
        let parts = coords.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return [] }
        func degrees(_ pixel: Int) -> Int { Int(Double(pixel) / pixelsPerDegree + 0.5) }
        let west = degrees(parts[0]) - 180, north = 90 - degrees(parts[1])
        let east = degrees(parts[2]) - 180, south = 90 - degrees(parts[3])
        var names: [String] = []
        for lon in west..<max(west, east) {
            for lat in south..<max(south, north) {
                let lonName = lon < 0 ? String(format: "W%03d", -lon) : String(format: "E%03d", lon)
                // By the rectangle's south edge, not the tile's own latitude.
                let latName = south < 0 ? String(format: "S%02d", -lat) : String(format: "N%02d", lat)
                names.append(latName + lonName)
            }
        }
        return names
    }

    /// Loads the index, building it from the coverage page if there is none cached.
    static func index(_ resolution: Int, log: (String) -> Void) async throws -> Index {
        let file = indexFile(resolution)
        if let cached = Index.load(file) { return cached }

        guard let url = coverageURL(resolution) else { throw Trouble.noIndex(resolution) }
        log("building the Viewfinder coverage index for view\(resolution)")
        Paths.ensure(Paths.hgtCache)
        // A plain GET rather than the downloader, which needs a Content-Length to divide
        // into byte ranges; the server compresses this page, so there is none.
        guard let data = try? await Downloader.retrying({ try await Fetch.data(url, timeout: coverageTimeout) })
        else { throw Trouble.noIndex(resolution) }
        // The page declares no dependable charset; latin-1 decodes any byte, and the bytes
        // that matter here are ASCII. Not Foundation's decoder: on Linux it returns nil
        // for a buffer the size of this page.
        let built = Index.parse(coveragePage: CodePage.latin1(data))
        guard !built.entries.isEmpty else { throw Trouble.noIndex(resolution) }
        try? built.save(to: file, resolution: resolution)
        log("indexed \(built.entries.count) Viewfinder archive(s) for view\(resolution)")
        return built
    }
}
