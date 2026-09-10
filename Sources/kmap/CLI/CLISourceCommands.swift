import Foundation

/// Commands for a map's source data: the OSM extract, the tiles it splits into, and the
/// elevation rasters converted to the `.hgt` the contour tracer reads. Each step of a build
/// is exposed on its own so it can be run and compared in isolation.
extension CLI {
    /// Splits an extract into tiles with kmap's own splitter, for comparison against
    /// splitter.jar on the same input.
    ///
    ///     kmap split extract.osm.pbf --output-dir tiles --mapid 63410001 \
    ///         --max-nodes 1600000 [--use-areas areas.list]
    static func split(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["output-dir", "mapid", "max-nodes",
                                              "description", "use-areas"])
        guard let input = flags.positionals.first,
              let outputDir = flags.value("output-dir") else {
            let usage = "usage: kmap split <extract.osm.pbf> --output-dir <dir> [--mapid N]"
                + " [--max-nodes N] [--description S] [--use-areas areas.list]"
            return CLIOutput.failure(usage, code: 2)
        }
        var areas: [TileSplitter.Area]?
        if let list = flags.value("use-areas") {
            guard let text = try? String(contentsOfFile: list, encoding: .utf8) else {
                return CLIOutput.failure("cannot read \(list)")
            }
            var parsed: [TileSplitter.Area] = []
            for line in text.split(separator: "\n") {
                // Line form: "63410001: 2041856,1599488 to 2170880,1710080"
                let row = line.trimmingCharacters(in: .whitespaces)
                guard !row.hasPrefix("#"), let colon = row.firstIndex(of: ":") else { continue }
                let body = row[row.index(after: colon)...]
                let corners = body.components(separatedBy: " to ")
                guard corners.count == 2 else { continue }
                let a = corners[0].split(separator: ",").compactMap {
                    Int32($0.trimmingCharacters(in: .whitespaces))
                }
                let b = corners[1].split(separator: ",").compactMap {
                    Int32($0.trimmingCharacters(in: .whitespaces))
                }
                guard a.count == 2, b.count == 2 else { continue }
                parsed.append(TileSplitter.Area(minLat: a[0], minLon: a[1],
                                                maxLat: b[0], maxLon: b[1]))
            }
            guard !parsed.isEmpty else {
                return CLIOutput.failure("no areas in \(list)")
            }
            areas = parsed
        }
        Paths.ensure(URL(fileURLWithPath: outputDir, isDirectory: true))
        let splitter = TileSplitter(options: .init(
            inputs: [URL(fileURLWithPath: input)],
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            mapID: flags.int("mapid") ?? 63410001,
            maxNodes: flags.int("max-nodes") ?? 1_600_000,
            description: flags.value("description") ?? "map",
            areas: areas)) { CLILog.line($0) }
        do {
            let started = Date()
            let result = try splitter.run()
            for tile in result.tiles {
                let a = tile.area
                CLILog.line(String(format: "%@  %.4f..%.4f / %.4f..%.4f  %d node(s)",
                             tile.mapID,
                             TileSplitter.degrees(a.minLat), TileSplitter.degrees(a.maxLat),
                             TileSplitter.degrees(a.minLon), TileSplitter.degrees(a.maxLon),
                             tile.nodes))
            }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(String(format: "split in %.1f s", seconds))
            CLIOutput.result([
                "outputDir": .string(outputDir),
                "tiles": .array(result.tiles.map { tile in
                    ["mapID": .string(tile.mapID), "nodes": .int(tile.nodes),
                     "minLat": .double(TileSplitter.degrees(tile.area.minLat)),
                     "minLon": .double(TileSplitter.degrees(tile.area.minLon)),
                     "maxLat": .double(TileSplitter.degrees(tile.area.maxLat)),
                     "maxLon": .double(TileSplitter.degrees(tile.area.maxLon))]
                }),
                "seconds": .double(seconds),
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// `--split=` if given, else `--parts=`, else the profile's own mode. Returns nil for an
    /// unrecognised word, which `SplitMode.init(settingsID:)` would silently take as `.fitCard`.
    static func splitMode(from flags: Flags, choices: BuildChoices,
                                  parts: Int?) -> SplitMode? {
        if let word = flags.value("split")?.lowercased() {
            guard ["fit", "region", "country", "custom"].contains(word) else { return nil }
            return SplitMode(settingsID: word, count: parts ?? choices.parts)
        }
        if let parts { return .count(parts) }
        return SplitMode(settingsID: choices.splitMode, count: choices.parts)
    }

    /// Maps region id to country id, walking up the tree until the parent is a continent.
    static func countries(of regions: [Region], in index: RegionIndex)
        -> [String: String] {
        var out: [String: String] = [:]
        for region in regions {
            var current = region
            while let parentID = current.parentID, let parent = index.region(parentID),
                  parent.parentID != nil {
                current = parent
            }
            out[region.id] = current.id
        }
        return out
    }

    /// What `kmap regions <query>` lists.
    enum RegionListing {
        /// No query: the continents.
        case roots
        /// The query is exactly the id of a region that has sub-regions: those.
        case opened(Region)
        /// Anything else: a search across every region.
        case search(String)
    }

    /// Chooses the listing for a query. Opening by exact id comes before searching, so
    /// `kmap regions europe` walks into Europe rather than finding it; a leaf's id still
    /// searches, which finds the leaf itself.
    static func regionListing(for query: String, in index: RegionIndex)
        -> (listing: RegionListing, regions: [Region]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return (.roots, index.children(of: nil)) }
        if let region = index.region(q) ?? index.region(q.lowercased()), region.hasChildren {
            return (.opened(region), index.children(of: region.id))
        }
        return (.search(q), index.search(q, limit: 60))
    }

    static func listRegions(query: String) async -> Int32 {
        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }

        let (listing, regions) = regionListing(for: query, in: index)
        var opened: Region?
        if case .opened(let region) = listing {
            opened = region
            CLILog.line("\(index.breadcrumb(region.id))\n")
        }
        // Wide enough for the longest id on show, and never narrower than the id itself.
        // `padding(toLength:)` truncates as readily as it pads, and at a fixed 34 the one
        // id longer than that — saint-helena-ascension-and-tristan-da-cunha — came out
        // cut in half and touching the name, which is the id somebody would then copy
        // into `kmap build` and be told does not exist.
        let idColumn = max(regions.map(\.id.count).max() ?? 0, 8)
        for region in regions {
            let mark = region.pbfURL == nil ? "  " : "· "
            let children = region.hasChildren ? "  (\(region.childIDs.count) sub-regions)" : ""
            let id = region.id + String(repeating: " ", count: idColumn - region.id.count)
            CLILog.line("\(mark)\(id)  \(region.name)\(children)")
            // A single search hit is described in full. Two boxes mean the region
            // crosses 180°.
            guard case .search = listing, regions.count == 1 else { continue }
            for box in region.boxes {
                CLILog.line("    \(box.display)   \(box.demTileCount) cell(s)")
            }
            if region.boxes.count > 1 {
                CLILog.line("    \(region.demTileCount) cell(s) in all — the box around both"
                      + " would be \(region.bbox.demTileCount)")
            }
        }
        // A search that matched nothing said nothing at all and exited 0, which reads
        // exactly like a search that worked. Every other command answers.
        if regions.isEmpty, case .search(let query) = listing {
            CLILog.line(t("nothing here answers to \"%@\"", query))
            CLIOutput.result(["in": .null, "regions": .array([])])
            return 1
        }
        if regions.contains(where: \.hasChildren) {
            CLILog.line("\nOpen a region with sub-regions:  kmap regions <id>")
        }
        if regions.contains(where: { $0.pbfURL != nil }) {
            CLILog.line("Build one:  kmap build <id>")
        }
        CLIOutput.result([
            "in": .of(opened?.id),
            "regions": .array(regions.map { region in
                ["id": .string(region.id), "name": .string(region.name),
                 "parent": .of(region.parentID),
                 "downloadable": .bool(region.pbfURL != nil),
                 "subRegions": .int(region.childIDs.count),
                 "demCells": .int(region.demTileCount),
                 "boxes": .array(region.boxes.map {
                     ["minLat": .double($0.minLat), "minLon": .double($0.minLon),
                      "maxLat": .double($0.maxLat), "maxLon": .double($0.maxLon)]
                 })]
            }),
        ])
        return 0
    }

    /// Converts one degree cell of GeoTIFF tiles into `.hgt`, for comparison against GDAL's
    /// output from the same tiles.
    ///
    ///     kmap tif2hgt N44E034 --dir tiles --out mine.hgt
    static func tif2hgt(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dir", "out"])
        guard let cell = flags.positionals.first, let directory = flags.value("dir"),
              let out = flags.value("out") else {
            return CLIOutput.failure(
                "usage: kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>", code: 2)
        }
        let sign = cell.hasPrefix("S") ? -1 : 1
        let east = cell.dropFirst().firstIndex(where: { $0 == "E" || $0 == "W" })
        guard let east else {
            return CLIOutput.failure("bad cell name: \(cell)", code: 2)
        }
        let lat = sign * (Int(cell[cell.index(after: cell.startIndex)..<east]) ?? 0)
        let lonSign = cell[east] == "W" ? -1 : 1
        let lon = lonSign * (Int(cell[cell.index(after: east)...]) ?? 0)

        let root = URL(fileURLWithPath: directory)
        let mosaic = HGTConversion.Mosaic { lat, lon in
            let file = root.appendingPathComponent(
                "\(CopernicusDEM.cellName(lat: lat, lon: lon)).tif")
            return FileTools.exists(file) ? file : nil
        }
        do {
            let started = Date()
            let count = try HGTConversion.write(cell: (lat: lat, lon: lon), from: mosaic,
                                                to: URL(fileURLWithPath: out))
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("\(count) node(s) written in " + String(format: "%.1f s", seconds))
            CLIOutput.result(["out": .string(out), "cell": .string(cell),
                              "nodes": .int(count), "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Reads a GeoTIFF with kmap's own reader, for comparison against GDAL's.
    ///
    ///     kmap tif cop.tif --dump samples.f32
    static func tif(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dump"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap tif <file.tif> [--dump <out.f32>]",
                                     code: 2)
        }
        do {
            let started = Date()
            let tiff = try GeoTIFF(contentsOf: URL(fileURLWithPath: path))
            CLILog.line("\(tiff.width)×\(tiff.height)")
            CLILog.line(String(format: "sample (0,0) at %.9f, %.9f", tiff.originLon, tiff.originLat))
            CLILog.line(String(format: "step %.12f lon, %.12f lat", tiff.stepLon, tiff.stepLat))
            if let dump = flags.value("dump") {
                var out = Data(capacity: tiff.width * tiff.height * 4)
                for r in 0..<tiff.height {
                    for value in try tiff.row(r) {
                        withUnsafeBytes(of: value.bitPattern.littleEndian) {
                            out.append(contentsOf: $0)
                        }
                    }
                }
                try out.write(to: URL(fileURLWithPath: dump))
                CLILog.line("wrote \(out.count) bytes")
            }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(String(format: "read in %.1f s", seconds))
            CLIOutput.result(["width": .int(tiff.width), "height": .int(tiff.height),
                              "originLon": .double(tiff.originLon),
                              "originLat": .double(tiff.originLat),
                              "stepLon": .double(tiff.stepLon),
                              "stepLat": .double(tiff.stepLat),
                              "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Fetches one elevation tile through kmap's own downloaders, for comparison against the
    /// tile pyhgtmap fetches for the same name.
    ///
    ///     kmap fetch-dem N44E034 --source view3
    static func fetchDEM(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["source"])
        guard let area = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap fetch-dem <area> [--source view1|view3]",
                                     code: 2)
        }
        let source = flags.value("source") ?? "view3"
        guard source.hasPrefix("view"), let resolution = Int(source.dropFirst(4)),
              resolution == 1 || resolution == 3 else {
            return CLIOutput.failure("unknown source: \(source)", code: 2)
        }

        let log = Log(showing: CLIOutput.showing)
        let runner = ProcessRunner()
        let downloader = Downloader(log: log)
        do {
            var index = try await ViewfinderDEM.index(resolution, downloader: downloader) {
                CLILog.line($0)
            }
            CLILog.line("index: \(index.entries.count) archive(s),"
                  + " \(index.urls(for: area).count) claim \(area)")
            let file = try await ViewfinderDEM.fetch(area, resolution: resolution,
                                                     index: &index, downloader: downloader,
                                                     runner: runner) { CLILog.line($0) }
            CLILog.line("\(file.path)  \(FileTools.size(of: file)) bytes")
            CLIOutput.result(["area": .string(area), "source": .string(source),
                              "file": .string(file.path),
                              "bytes": .int(Int(FileTools.size(of: file))),
                              "archives": .int(index.entries.count)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// The pristine rule stage recovery reads and writes against.
    private static func neutralRules(log: Log) async throws -> URL {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        return try await catalog.neutralRulesForRecovery(log: log,
                                                         runner: ProcessRunner())
    }

    /// Tag-by-tag comparison of two maps: what the original draws each meaning with,
    /// against what the rebuilt map draws it with. The full test of a style recovery —
    /// every tag, before and after.
    ///
    ///     kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…
    static func recoverCheck(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract"])
        guard flags.positionals.count == 2 else {
            return CLIOutput.failure("usage: kmap recover-check <original.img>"
                                     + " <rebuilt.img> [--extract=FILE.pbf]…", code: 2)
        }
        let extracts = flags.values("extract").map { URL(fileURLWithPath: $0) }
        let log = Log(showing: CLIOutput.showing)
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let original = try await StyleRecovery.run(
                img: Paths.expand(flags.positionals[0]), extracts: extracts, log: log,
                rulesDirectory: neutral)
            let rebuilt = try await StyleRecovery.run(
                img: Paths.expand(flags.positionals[1]), extracts: extracts, log: log,
                rulesDirectory: neutral)

            func top(_ codes: [String: Int]) -> [(String, Int)] {
                let total = codes.values.reduce(0, +)
                // A code carrying under a tenth of the tag is a stray, not a mapping.
                return codes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                    .filter { $0.value * strayBelow >= total }
            }
            // A recovered style puts their pictures on our numbers, so where both maps
            // carry a TYP the tags are compared by picture, not by number.
            let theirTyp = typSource(of: Paths.expand(flags.positionals[0]))
            let ourTyp = typSource(of: Paths.expand(flags.positionals[1]))
            func pictures(_ codes: [(String, Int)], in typ: TypSource) -> [XpmBlock] {
                codes.compactMap { picture(of: $0.0, in: typ) }
            }

            var same = 0
            var different: [(tag: String, theirs: String, ours: String)] = []
            var missing: [(tag: String, theirs: String, count: Int)] = []
            for (tag, theirCodes) in original.codesByTag.sorted(by: { $0.key < $1.key }) {
                let witnesses = theirCodes.values.reduce(0, +)
                guard witnesses >= fewestCompared else { continue }
                let theirTop = top(theirCodes)
                let ourCodes = rebuilt.codesByTag[tag] ?? [:]
                guard !ourCodes.isEmpty else {
                    // An omission is only an omission where the rebuilt map's ground
                    // carries the tag at all: two maps over two grounds share styles,
                    // not dachas.
                    if rebuilt.groundTags[tag] ?? 0 >= fewestCompared {
                        missing.append((tag, theirTop.map(\.0).joined(separator: ","),
                                        witnesses))
                    }
                    continue
                }
                let ourTop = top(ourCodes)
                let theirs = theirTop.map(\.0).joined(separator: ",")
                let ours = ourTop.map(\.0).joined(separator: ",")
                // A settlement is drawn by the receiver itself on both maps, whatever
                // number each gives it.
                if theirTop.contains(where: { isCity($0.0) }),
                   ourTop.contains(where: { isCity($0.0) }) {
                    same += 1
                    continue
                }
                if let theirTyp, let ourTyp {
                    let wanted = pictures(theirTop, in: theirTyp)
                    let got = pictures(ourTop, in: ourTyp)
                    // Nothing painted on either side: the numbers say what agrees.
                    if wanted.isEmpty, got.isEmpty {
                        if ourTop.contains(where: { mine in theirTop.contains { $0.0 == mine.0 } }) {
                            same += 1
                        } else {
                            different.append((tag, theirs, ours))
                        }
                    } else if got.contains(where: { wanted.contains($0) }) {
                        same += 1
                    } else {
                        different.append((tag, theirs + (wanted.isEmpty ? " (unpainted)" : ""),
                                          ours + (got.isEmpty ? " (unpainted)" : "")))
                    }
                    continue
                }
                // Agreement: our commonest code for the tag is one the original uses.
                if ourTop.contains(where: { mine in theirTop.contains { $0.0 == mine.0 } }) {
                    same += 1
                } else {
                    different.append((tag, theirs, ours))
                }
            }

            CLILog.line("")
            CLILog.line("tags compared: \(same + different.count),"
                        + " agreeing \(same), differing \(different.count),"
                        + " undrawn by the rebuilt map \(missing.count)")
            for d in different {
                CLILog.line(String(format: "  DIFF  %-40@ theirs %@  ours %@",
                                   d.tag as NSString, d.theirs, d.ours))
            }
            for m in missing {
                CLILog.line(String(format: "  MISS  %-40@ theirs %@ ×%d, ours nothing",
                                   m.tag as NSString, m.theirs, m.count))
            }
            CLIOutput.result([
                "agreeing": .int(same),
                "differing": .array(different.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs),
                     "ours": .string($0.ours)]
                }),
                "missing": .array(missing.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs),
                     "count": .int($0.count)]
                }),
            ])
            return different.isEmpty && missing.isEmpty ? 0 : 1
        } catch {
            return CLIOutput.failure("recover-check: \(error.localizedDescription)")
        }
    }

    /// A tag is compared once this many of its objects were identified, and a code
    /// carrying under one part in this many of the tag is a stray, not a mapping.
    private static let fewestCompared = 6
    private static let strayBelow = 10

    /// The TYP a map carries, as source, or nil where it carries none.
    private static func typSource(of img: URL) -> TypSource? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString).typ")
        defer { FileTools.removeIfPresent(scratch) }
        guard ImgContainer.extractTYP(from: img, to: scratch),
              let binary = try? TypBinary.read(scratch) else { return nil }
        return TypSource.parse(TypDecompiler.source(binary))
    }

    /// Whether an evidence key names a settlement point, `P600` and its kin.
    private static func isCity(_ key: String) -> Bool {
        guard key.first == ElementDumper.Kind.point.rawValue,
              let code = Int(key.dropFirst(), radix: 16) else { return false }
        return GarminStandard.cityTypes.contains(code)
    }

    /// What a code draws in a TYP, keyed as the evidence keys codes: `A50`, `L11f14`.
    private static func picture(of key: String, in typ: TypSource) -> XpmBlock? {
        guard let first = key.first, let kind = ElementDumper.Kind(rawValue: first),
              let code = Int(key.dropFirst(), radix: 16) else { return nil }
        // The drawing itself, a plain fill included: `picture` leaves solid ones out.
        return typ.section(kind.styleKind, code).flatMap { $0.dayXpm ?? $0.xpm }
    }

    /// What the elevation for a region will cost to download, per source, before any
    /// build: the same cells and the same source chain the build fetches.
    ///
    ///     kmap dem-cost crimean-fed-district --sources=copernicus1,copernicus3
    static func demCost(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["sources"])
        guard let regionID = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap dem-cost <region>[+<region>…]"
                                     + " [--sources=<list>]", code: 2)
        }
        let sources = flags.value("sources") ?? BuildRecipe.recommendedDEMSources

        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }
        var chosen: [Region] = []
        for id in regionID.split(separator: "+").map(String.init) {
            guard let found = index.region(id) else {
                return CLIOutput.failure("no region with id \"\(id)\""
                                         + " — try `kmap regions \(id)`", code: 2)
            }
            chosen.append(found)
        }

        let started = Date()
        let cells = await ElevationCost.cells(of: chosen)
        let estimates = await ElevationCost.estimate(sources: sources, cells: cells)
        CLILog.line("\(chosen.map(\.name).joined(separator: " + ")):"
                    + " \(cells.count) cell(s) after the outline trim")
        for e in estimates {
            var line = "\(e.source): "
            if e.cached > 0 { line += "\(e.cached) cached · " }
            if e.wanted == 0 {
                line += "nothing to fetch — cached or already covered"
            } else if let bytes = e.bytes, bytes > 0 {
                line += "about \(Fmt.bytes(bytes)) — "
                line += e.archives > 0 ? "\(e.archives) zone archive(s)"
                                       : "\(e.published) tile(s)"
                line += e.exact ? ", every size asked" : ", measured on \(e.sampled)"
                if let note = e.note { line += " · \(note)" }
            } else if e.bytes == 0 {
                line += e.note ?? "nothing to fetch"
            } else {
                line += e.note ?? "\(e.wanted) cell(s), unmeasured"
            }
            CLILog.line(line)
        }
        let total = estimates.reduce(Int64(0)) { $0 + max(0, $1.bytes ?? 0) }
        if estimates.filter({ ($0.bytes ?? 0) > 0 }).count > 1 {
            CLILog.line("\(Fmt.bytes(total)) to download in all")
        }
        CLIOutput.result([
            "regions": .array(chosen.map { .string($0.id) }),
            "sources": .string(sources),
            "cells": .int(cells.count),
            "totalBytes": .int(Int(total)),
            "estimates": .array(estimates.map { e in
                var fields: [String: JSONValue] = [
                    "source": .string(e.source),
                    "cells": .int(e.cells),
                    "cached": .int(e.cached),
                    "wanted": .int(e.wanted),
                    "published": .int(e.published),
                    "exact": .bool(e.exact),
                    "sampled": .int(e.sampled),
                    "archives": .int(e.archives),
                ]
                fields["bytes"] = e.bytes.map { .int(Int($0)) } ?? .null
                if let note = e.note { fields["note"] = .string(note) }
                return .object(fields)
            }),
            "seconds": .double(Date().timeIntervalSince(started)),
        ])
        return 0
    }
}

extension CLI {
    /// `kmap img-elements <map.img> --out <dump.bin> [--ground minLat,minLon,maxLat,maxLon]…`
    /// writes the map's detail-level elements in the binary form mkgmap's reader produces,
    /// for a byte-for-byte comparison. `--extended` adds extended-type polygons and points.
    static func imgElements(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["out", "ground", "res"])
        guard let path = flags.positionals.first, let out = flags.value("out") else {
            return CLIOutput.failure("usage: kmap img-elements <map.img> --out <dump.bin>"
                                     + " [--ground a,b,c,d]… [--extended]"
                                     + " [--coarse] [--res=N]", code: 2)
        }
        var grounds: [BBox] = []
        for spec in flags.values("ground") {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                return CLIOutput.failure("bad --ground: \(spec)", code: 2)
            }
            grounds.append(BBox(minLon: parts[1], minLat: parts[0], maxLon: parts[3], maxLat: parts[2]))
        }
        if grounds.isEmpty { grounds = [BBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90)] }
        do {
            var dump = ElementDumper.Dump()
            let started = Date()
            try ImgElements.read(img: Paths.expand(path),
                                 grounds: grounds.map(ImgElements.Ground.init),
                                 extendedAreasAndPoints: flags.has("extended"),
                                 coarserLevels: flags.has("coarse"),
                                 resolution: flags.value("res").flatMap { Int($0) },
                                 tick: {}) { kind, type, coords in
                let from = dump.cells.count
                for c in coords { dump.cells.append(GarminGrid.pack(latUnit: c.lat, lonUnit: c.lon)) }
                dump.elements.append(ElementDumper.Element(kind: kind, type: type,
                                                           from: Int32(from), count: Int32(coords.count)))
            }
            try ElementDumper.write(dump, to: Paths.expand(out))
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("\(dump.count) element(s), \(dump.cells.count) vertice(s) in "
                  + String(format: "%.1f s", seconds))
            CLIOutput.result(["out": .string(out), "elements": .int(dump.count),
                              "vertices": .int(dump.cells.count),
                              "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// `kmap recover <map.img> [--extract file.pbf]…` reads a third-party map and writes
    /// its look back out as a style of kmap's own: their pictures on kmap's numbers.
    static func recover(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract", "out", "sheet"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap recover <map.img> [--extract <file.pbf>]…"
                                     + " [--out <style.typ.txt>] [--sheet <file>]", code: 2)
        }
        let explicit = flags.values("extract").map { Paths.expand($0) }
        let log = Log(showing: CLIOutput.showing)
        // The log is drained after the run, since every stage appends and returns.
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let report = try await StyleRecovery.run(
                img: Paths.expand(path), extracts: explicit, log: log,
                rulesDirectory: neutral)
            for line in log.snapshot() { CLILog.line(line.text) }
            let ordered = report.outcomes.values.sorted {
                ($0.kind.rawValue, $0.type) < ($1.kind.rawValue, $1.type)
            }
            try printRecovery(report, ordered: ordered, sheet: flags.value("sheet"))
            reportRecoveryJSON(report, ordered: ordered, path: path,
                               out: flags.value("out"))
            if let refusal = writeRecoveredStyle(report, mapPath: path,
                                                 to: flags.value("out"),
                                                 adopt: flags.has("attach")) {
                return refusal
            }
            return 0
        } catch StyleRecovery.Trouble.noExtracts(let frame) {
            return await suggestExtracts(for: frame, path: path)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
    }

    /// Saves what the recovery produced — the style to `--out`, into the library where
    /// `--attach` says so — and names what had nowhere to land. Returns a failure code.
    private static func writeRecoveredStyle(_ report: StyleRecovery.Report,
                                            mapPath: String, to out: String?,
                                            adopt: Bool) -> Int32? {
        guard !report.style.isEmpty else {
            return out == nil && !adopt ? nil
                : CLIOutput.failure("recover: nothing to save — no style was recovered")
        }
        if let out {
            let url = Paths.expand(out)
            do {
                try report.style.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return CLIOutput.failure("recover: \(error)")
            }
            CLILog.line("style -> \(Paths.display(url))")
        }
        if adopt, let refusal = updateLibraryStyle(report, mapPath: mapPath) {
            return refusal
        }
        // One number of ours that several looks of theirs wanted: where a rule of
        // ours lumps together what their style tells apart.
        if !report.contested.isEmpty {
            CLILog.line("")
            CLILog.line("one number of ours, several looks of theirs (the winner first):")
            for port in report.contested {
                let kind = port.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                let rivals = port.rivals.map {
                    "\($0.meaning) <- 0x\(String($0.theirs, radix: 16)) (\($0.witnesses))"
                }.joined(separator: ", ")
                CLILog.line("  \(kind) 0x\(String(port.ours, radix: 16))"
                            + "  \(port.meaning) <- 0x\(String(port.theirs, radix: 16))"
                            + " (\(port.witnesses))  over  \(rivals)")
            }
        }
        // What their style draws and kmap has no number for: the list that says where
        // the rule base wants widening.
        guard !report.uncovered.isEmpty else { return nil }
        CLILog.line("")
        CLILog.line("their style draws these, and kmap's rules have no number for them:")
        for entry in report.uncovered.prefix(40) {
            let kind = entry.kind.rawValue.padding(toLength: 8, withPad: " ",
                                                   startingAt: 0)
            CLILog.line("  \(kind) 0x\(String(entry.theirs, radix: 16))"
                        + "  \(entry.meaning) — \(entry.witnesses) seen")
        }
        if report.uncovered.count > 40 {
            CLILog.line("  … and \(report.uncovered.count - 40) more")
        }
        return nil
    }

    /// The recovery on screen: the frame and one line per code. The reassignment list
    /// is written only where `--sheet` asks for it.
    private static func printRecovery(_ report: StyleRecovery.Report,
                                      ordered: [StyleRecovery.Outcome],
                                      sheet: String?) throws {
        CLILog.line("")
        CLILog.line("frame     \(report.frame.display)")
        CLILog.line("extracts  \(report.extracts.map(\.lastPathComponent).joined(separator: ", "))")
        CLILog.line("elements  \(report.elements)")
        CLILog.line("")
        for o in ordered {
            let code = String(format: "%@ 0x%05x", String(o.kind.rawValue), o.type)
            CLILog.line("\(code)  \(o.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + " witnesses=\(o.witnesses)/\(o.elements)"
                + (o.zooms.map { " " + $0 } ?? "")
                + (o.meaning.isEmpty ? "" : "  \(o.meaning)"))
        }
        if let sheet {
            try (report.sheet + "\n").write(to: Paths.expand(sheet),
                                             atomically: true, encoding: .utf8)
            CLILog.line("\nsheet -> \(sheet)")
        }
    }

    /// The same recovery in the structured shape.
    private static func reportRecoveryJSON(_ report: StyleRecovery.Report,
                                           ordered: [StyleRecovery.Outcome],
                                           path: String, out: String?) {
        CLIOutput.result([
            "map": .string(Paths.expand(path).path),
            "frame": ["minLat": .double(report.frame.minLat),
                      "minLon": .double(report.frame.minLon),
                      "maxLat": .double(report.frame.maxLat),
                      "maxLon": .double(report.frame.maxLon)],
            "extracts": .array(report.extracts.map { .string($0.path) }),
            "elements": .int(report.elements),
            "outcomes": .array(ordered.map { outcome in
                ["kind": .string(String(outcome.kind.rawValue)),
                 "type": .int(outcome.type),
                 "hex": .string(String(format: "0x%05x", outcome.type)),
                 "status": .string(outcome.status.rawValue),
                 "witnesses": .int(outcome.witnesses),
                 "elements": .int(outcome.elements),
                 "unmatched": .int(outcome.unmatched),
                 "ambiguous": .int(outcome.ambiguous),
                 "meaning": .string(outcome.meaning)]
            }),
            "sheet": .string(report.sheet),
            "contested": .array(report.contested.map { port in
                ["kind": .string(port.kind.rawValue), "ours": .int(port.ours),
                 "theirs": .int(port.theirs), "meaning": .string(port.meaning),
                 "witnesses": .int(port.witnesses),
                 "rivals": .array(port.rivals.map {
                     ["theirs": .int($0.theirs), "meaning": .string($0.meaning),
                      "witnesses": .int($0.witnesses)]
                 })]
            }),
            // The whole list, where the printed one stops at forty.
            "uncovered": .array(report.uncovered.map { entry in
                ["kind": .string(entry.kind.rawValue),
                 "theirs": .int(entry.theirs),
                 "hex": .string(String(format: "0x%05x", entry.theirs)),
                 "meaning": .string(entry.meaning),
                 "witnesses": .int(entry.witnesses)]
            }),
            "out": .of(out),
        ])
    }

    /// `--attach`: the library entry this map's TYP was imported as becomes the
    /// recovered style. Found by fingerprint, since a person may have renamed it.
    private static func updateLibraryStyle(_ report: StyleRecovery.Report,
                                           mapPath path: String) -> Int32? {
        let held = TypLibrary.held()
        guard let name = held.exact[TypLibrary.fingerprint(
            ofTypAt: Paths.expand(path))] else {
            return CLIOutput.failure("--attach: this map's TYP is not in the library"
                + " — import it first with: kmap extract-typ\n")
        }
        guard let typ = TypLibrary.contents().first(where: {
            $0.deletingPathExtension().lastPathComponent == name
        }) else {
            return CLIOutput.failure(
                "--attach: \(name) is listed but its file was not found")
        }
        do {
            try TypLibrary.save(report.style, to: typ)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
        // The reassignment list went with the old file: no foreign numbers are left.
        if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
        CLILog.line("\(typ.lastPathComponent) now draws this map's look"
                    + " — build with --style=typ:"
                    + typ.deletingPathExtension().lastPathComponent)
        return nil
    }

    /// What to do when no downloaded OSM data matches the map: name the candidate
    /// downloads rather than fetching them.
    private static func suggestExtracts(for frame: BBox, path: String) async -> Int32 {
        CLILog.error("recover: no downloaded OSM data matches \(frame.display)")
        let index = RegionIndex()
        guard (try? await index.load()) != nil else { return 1 }
        let wanted = RegionSuggestion.suggestedRegions(
            on: RegionSuggestion.drawnGround(of: Paths.expand(path)), index: index)
        guard !wanted.isEmpty else {
            return CLIOutput.failure("and no region kmap can download overlaps it either")
        }
        CLIOutput.result(["needsExtract": .bool(true),
                          "frame": ["minLat": .double(frame.minLat),
                                    "minLon": .double(frame.minLon),
                                    "maxLat": .double(frame.maxLat),
                                    "maxLon": .double(frame.maxLon)],
                          "suggested": .array(wanted.prefix(6).map { candidate in
                              ["region": .string(candidate.region.id),
                               "share": .double(candidate.share),
                               "drawnBytes": .double(candidate.drawn),
                               "inside": .double(candidate.inside)]
                          })])
        // One region inside the map suffices, so these are alternatives, not a set.
        CLILog.line("\nAny one of these regions is ground enough — download with:")
        for candidate in wanted.prefix(6) {
            CLILog.line(String(format: "  kmap build %@  (holds %.0f%% of the map's data,"
                         + " %.1f MB of it; %.0f%% of the region is under the map)",
                         candidate.region.id, candidate.share * 100,
                         candidate.drawn / 1_048_576, candidate.inside * 100))
        }
        CLILog.line("\nor pass an extract of your own with --extract=<file.osm.pbf>")
        return 1
    }
}
