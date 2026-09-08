import Foundation

/// Commands that drive one pass each, for running a step without a whole build: scanning
/// an extract, repairing its roads, burning peaks into a DEM tile, making a POI file,
/// checking coverage, dumping a TYP and folding Assets/ back into the binary.

extension CLI {

    static func osmScan(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["dump"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap osm-scan <file.osm.pbf>", code: 2)
        }
        let started = Date()
        if flags.has("load") {
            do {
                let network = try RoadNetworkLoader(url: URL(fileURLWithPath: path)).load()
                let loadSeconds = Date().timeIntervalSince(started)
                CLILog.line("routable ways: \(network.wayCount), points \(network.refs.count)")
                CLILog.line("obstacles:     \(network.obstacleCount), points \(network.obstacleLat.count)")
                CLILog.line(String(format: "loaded in %.1f s", loadSeconds))
                let scan = Date()
                let (found, loose) = RoadRepair(network: network, limit: 5.0).candidates()
                let scanSeconds = Date().timeIntervalSince(scan)
                CLILog.line("road ends within 5.0 m of another line: \(found.count)")
                CLILog.line(String(format: "scanned in %.1f s", scanSeconds))

                let judging = Date()
                let hgt = CopernicusDEM.cacheDirectory
                let dem = FileManager.default.fileExists(atPath: hgt.path) ? Terrain(directory: hgt) : nil
                let plan = RepairPlanner(network: network, terrain: dem, bridging: true, limit: 5.0)
                    .plan(found, loose: loose)
                let inserts = plan.inserts.values.reduce(0) { $0 + $1.count }
                let judgeSeconds = Date().timeIntervalSince(judging)
                // Commonest first, and by name where two are equally common: a dictionary
                // has no order of its own, and this list is compared between runs.
                for (reason, count) in plan.counts.sorted(by: {
                    ($0.value, $1.key) > ($1.value, $0.key)
                }) {
                    CLILog.line("  \(reason): \(count)")
                }
                CLILog.line("  moves \(plan.moves.count), merges \(plan.merges.count), "
                      + "inserts \(inserts), bridges \(plan.bridges.count)")
                CLILog.line(String(format: "judged in %.1f s", judgeSeconds))
                if let dump = flags.value("dump") {
                    try? plan.trace.sorted().joined(separator: "\n")
                        .write(toFile: dump, atomically: true, encoding: .utf8)
                }
                CLIOutput.result([
                    "routableWays": .int(network.wayCount),
                    "routablePoints": .int(network.refs.count),
                    "obstacles": .int(network.obstacleCount),
                    "obstaclePoints": .int(network.obstacleLat.count),
                    "candidates": .int(found.count),
                    "verdicts": .object(plan.counts.mapValues { .int($0) }),
                    "moves": .int(plan.moves.count),
                    "merges": .int(plan.merges.count),
                    "inserts": .int(inserts),
                    "bridges": .int(plan.bridges.count),
                    "seconds": ["load": .double(loadSeconds), "scan": .double(scanSeconds),
                                "judge": .double(judgeSeconds)],
                ])
                return 0
            } catch {
                return CLIOutput.failure("cannot read \(path): \(error)")
            }
        }
        var census = OSMCensus()
        do {
            try PBFReader(url: URL(fileURLWithPath: path)).read(into: &census)
        } catch {
            return CLIOutput.failure("cannot read \(path): \(error)")
        }
        let seconds = Date().timeIntervalSince(started)
        CLILog.line("nodes:         \(census.nodes)")
        CLILog.line("ways:          \(census.ways)")
        CLILog.line("routable ways: \(census.roads), points \(census.roadPoints)")
        CLILog.line("obstacles:     \(census.obstacles), points \(census.obstaclePoints)")
        CLILog.line("addresses:     \(census.addresses) object(s) carry addr:housenumber")
        CLILog.line(String(format: "read in %.1f s", seconds))
        CLIOutput.result(["nodes": .int(census.nodes), "ways": .int(census.ways),
                          "addresses": .int(census.addresses),
                          "routableWays": .int(census.roads),
                          "routablePoints": .int(census.roadPoints),
                          "obstacles": .int(census.obstacles),
                          "obstaclePoints": .int(census.obstaclePoints),
                          "seconds": .double(seconds)])
        return 0
    }

    /// Repair the road ends OSM left short of their junction, writing a repaired copy.
    static func repairRoads(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["labels", "limit"])
        let files = flags.positionals
        guard files.count >= 2 else {
            let usage = "usage: kmap repair-roads <in.osm.pbf> <out.osm.pbf> [--labels ru|en]"
                + " [--limit M] [--drop-duplicate-descriptions] [--mark-duplicate-venues]"
                + " [--no-bridges]"
            return CLIOutput.failure(usage, code: 2)
        }

        var pass = AnnotatePass(source: URL(fileURLWithPath: files[0]),
                                destination: URL(fileURLWithPath: files[1]))
        pass.repairRadius = flags.double("limit") ?? 5
        pass.bridgeObstacles = !flags.has("no-bridges")
        pass.language = flags.value("labels") ?? "en"
        pass.dropDuplicateDescriptions = flags.has("drop-duplicate-descriptions")
        pass.markDuplicateVenues = flags.has("mark-duplicate-venues")
        pass.dem = CopernicusDEM.cacheDirectory

        let started = Date()
        do {
            let tally = try pass.run { note in CLILog.line(note) }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("blocks copied \(tally.copied), rebuilt \(tally.rebuilt);"
                  + " added \(tally.addedNodes) node(s) and \(tally.addedWays) link(s)")
            CLILog.line(String(format: "done in %.1f s", seconds))
            CLIOutput.result(["out": .string(files[1]),
                              "blocksCopied": .int(tally.copied),
                              "blocksRebuilt": .int(tally.rebuilt),
                              "addedNodes": .int(tally.addedNodes),
                              "addedWays": .int(tally.addedWays),
                              "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("repair failed: \(error)")
        }
    }

    /// Write OSM summit heights into a copy of the .hgt tiles.
    static func burnPeaks(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["pbf", "hgt-dir", "out", "threshold", "radius"])
        guard let pbf = flags.value("pbf"), let source = flags.value("hgt-dir"),
              let out = flags.value("out") else {
            let usage = "usage: kmap burn-peaks --pbf <file> --hgt-dir <dir> --out <dir>"
                + " [--threshold M] [--radius M] [--quiet]"
            return CLIOutput.failure(usage, code: 2)
        }

        var burn = BurnPeaks(pbf: URL(fileURLWithPath: pbf),
                             hgt: URL(fileURLWithPath: source),
                             out: URL(fileURLWithPath: out))
        burn.threshold = flags.double("threshold") ?? 60
        burn.radius = flags.double("radius") ?? 100

        do {
            let report = try burn.run()
            let gains = report.gains.sorted()
            CLIOutput.result([
                "peaks": .int(report.peaks), "raised": .int(report.raised),
                "already": .int(report.already), "rejected": .int(report.rejected.count),
                "outside": .int(report.outside),
                "tiles": .array(report.written.map(JSONValue.string)),
                "gain": gains.isEmpty ? .null
                    : ["median": .int(gains[gains.count / 2]),
                       "mean": .double(Double(gains.reduce(0, +)) / Double(gains.count)),
                       "largest": .int(gains.last ?? 0)],
            ])
            if flags.has("quiet") {
                CLILog.line("\(report.raised) summit height(s) written into \(report.written.count)"
                      + " tile(s), \(report.rejected.count) rejected as bad OSM")
                return 0
            }
            CLILog.line("summits with a usable height : \(report.peaks)")
            CLILog.line("  raised                     : \(report.raised)")
            CLILog.line("  already at or above `ele`  : \(report.already)")
            CLILog.line("  rejected as bad OSM        : \(report.rejected.count)")
            CLILog.line("  outside the cached tiles   : \(report.outside)")
            if !gains.isEmpty {
                let mean = Double(gains.reduce(0, +)) / Double(gains.count)
                CLILog.line(String(format: "  gain: median %d m, mean %.1f m, largest %d m",
                             gains[gains.count / 2], mean, gains.last ?? 0))
            }
            CLILog.line("tiles written                : "
                  + (report.written.isEmpty ? "none" : report.written.joined(separator: ", ")))
            for item in report.rejected {
                let name = item.name.isEmpty ? "(unnamed)" : item.name
                CLILog.line(String(format: "  rejected %-22@ ele %-7.0f terrain %-7@ %@",
                             String(name.prefix(22)) as NSString, item.ele,
                             (item.terrain.map(String.init) ?? "n/a") as NSString,
                             item.why as NSString))
            }
            return 0
        } catch {
            return CLIOutput.failure("burn-peaks failed: \(error)")
        }
    }

    /// Build a Garmin Custom POI file of everything carrying a description.
    static func makeGPI(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["codepage", "category", "prefer", "exclude"])
        let files = flags.positionals
        guard files.count >= 2 else {
            let usage = "usage: kmap make-gpi <in.osm.pbf> <out.gpi> [--codepage cp1251]"
                + " [--category NAME] [--prefer ru] [--show-on-map] [--exclude k=v,...]"
            return CLIOutput.failure(usage, code: 2)
        }

        var gpi = MakeGPI(source: URL(fileURLWithPath: files[0]),
                          destination: URL(fileURLWithPath: files[1]))
        gpi.codepage = flags.value("codepage") ?? "cp1251"
        gpi.category = flags.value("category") ?? "kmap"
        gpi.prefer = flags.value("prefer") ?? "ru"
        gpi.showOnMap = flags.has("show-on-map")
        gpi.exclude = flags.values("exclude")

        do {
            let report = try gpi.run()
            var notes: [String] = ["\(report.fromNodes) from nodes, \(report.fromAreas) from areas"]
            if report.uninformative > 0 { notes.append("\(report.uninformative) dropped as uninformative") }
            if report.excluded > 0 { notes.append("\(report.excluded) omitted as hidden") }
            CLILog.line(String(format: "%d described POI(s) → %@ (%.1f kB)%@",
                         report.written, gpi.destination.lastPathComponent as NSString,
                         Double(report.bytes) / 1000.0,
                         (notes.isEmpty ? "" : "; " + notes.joined(separator: ", ")) as NSString))
            CLIOutput.result(["out": .string(gpi.destination.path),
                              "written": .int(report.written),
                              "bytes": .int(report.bytes),
                              "fromNodes": .int(report.fromNodes),
                              "fromAreas": .int(report.fromAreas),
                              "uninformative": .int(report.uninformative),
                              "excluded": .int(report.excluded)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Whether a built map's tiles cover the ground they claim: every tile's box, the box
    /// around them all, and each sample point belonging to no tile.
    ///
    /// - Returns: 1 when there are holes, 0 otherwise.
    static func coverage(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["step"])
        guard let path = flags.positionals.first, !path.hasPrefix("-") else {
            return CLIOutput.failure("usage: kmap coverage <map.img> [--step 0.25] [--quiet]",
                                     code: 2)
        }
        let step = flags.double("step") ?? 0.25
        let quiet = flags.has("quiet")

        let url = URL(fileURLWithPath: path)
        let tiles = MapCoverage.tiles(in: url)
        guard let report = MapCoverage.check(tiles, step: step) else {
            return CLIOutput.failure(t("no map tiles found"), code: 2)
        }
        if !quiet {
            for tile in report.tiles {
                CLILog.line(String(format: "%@  %9.4f %9.4f  ->  %9.4f %9.4f", tile.name,
                             tile.minLat, tile.minLon, tile.maxLat, tile.maxLon))
            }
        }
        CLILog.line(String(format: "covered: %.4f %.4f -> %.4f %.4f   (%d tiles)",
                     report.minLat, report.minLon, report.maxLat, report.maxLon,
                     report.tiles.count))
        CLILog.line(t("%d of %d sample(s) fall in no tile", report.holes.count, report.sampled))
        for hole in report.holes.prefix(40) {
            CLILog.line(String(format: "  hole %.2f %.2f", hole.lat, hole.lon))
        }
        if report.holes.count > 40 {
            CLILog.line(t("  ... and %d more", report.holes.count - 40))
        }
        CLIOutput.result([
            "map": .string(url.path),
            "tiles": .array(report.tiles.map {
                ["name": .string($0.name), "minLat": .double($0.minLat),
                 "minLon": .double($0.minLon), "maxLat": .double($0.maxLat),
                 "maxLon": .double($0.maxLon)]
            }),
            "covered": ["minLat": .double(report.minLat), "minLon": .double(report.minLon),
                        "maxLat": .double(report.maxLat), "maxLon": .double(report.maxLon)],
            "sampled": .int(report.sampled),
            "holes": .array(report.holes.map {
                ["lat": .double($0.lat), "lon": .double($0.lon)]
            }),
            "step": .double(step),
        ])
        return report.holes.isEmpty ? 0 : 1
    }

    /// Folds Assets/ back into Sources/kmap/Build/Style/StyleAssets.swift. The generated file
    /// is committed source, so a build needs nothing but `swift build`.
    static func embedAssets(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["assets", "out"])
        let root = URL(fileURLWithPath: flags.value("assets") ?? AssetEmbedder.defaultRoot)
        let out = URL(fileURLWithPath: flags.value("out") ?? AssetEmbedder.defaultOutput)
        do {
            let text = try AssetEmbedder.render(from: root)
            try text.write(to: out, atomically: true, encoding: .utf8)
            CLILog.line(t("wrote %@ (%@)", out.path, Fmt.bytes(Int64(text.utf8.count))))
            CLIOutput.result(["out": .string(out.path), "bytes": .int(text.utf8.count)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Decodes a compiled TYP and prints what is in it: colours, widths, pictures, labels and
    /// the draw order. Takes a `.typ` or a `.img`, lifting the TYP out of a map first.
    static func typdump(_ arguments: [String]) -> Int32 {
        let flags = CLI.Flags(arguments, valued: ["type"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure(
                "usage: kmap typdump <file.typ|map.img> [--polygons] [--lines] [--points]"
                + " [--draw-order] [--all] [--type=0xNN]\n", code: 2)
        }
        let url = Paths.expand(path)
        guard FileTools.exists(url) else {
            return CLIOutput.failure("\(url.lastPathComponent): not found", code: 2)
        }

        // A map rather than a TYP: lift it out into a place that goes away again.
        var typURL = url
        var lifted: URL?
        defer { if let lifted { FileTools.removeIfPresent(lifted.deletingLastPathComponent()) } }
        if ImgContainer.isImg(url) {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("kmap-typdump-\(UUID().uuidString.prefix(8))")
            Paths.ensure(staging)
            // A file path, not the directory: extractTYP writes to the exact URL given.
            let landed = staging.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".typ")
            guard ImgContainer.extractTYP(from: url, to: landed) else {
                return CLIOutput.failure("\(url.lastPathComponent): " + t("no TYP inside"))
            }
            typURL = landed
            lifted = landed
        }

        let typ: TypBinary
        do {
            typ = try TypBinary.read(typURL)
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }

        let wantedTypes: Set<Int> = Set(flags.values("type").compactMap { text -> Int? in
            Int(text.hasPrefix("0x") ? text.dropFirst(2) : text[...], radix: 16)
        })
        let all = flags.has("all")
        var kinds: [MapElementKind] = []
        if all || flags.has("polygons") { kinds.append(.polygon) }
        if all || flags.has("lines") { kinds.append(.line) }
        if all || flags.has("points") { kinds.append(.point) }
        if kinds.isEmpty && !wantedTypes.isEmpty { kinds = [.polygon, .line, .point] }

        CLILog.line("\(typURL.lastPathComponent)")
        CLILog.line("  " + t("code page %d · family %d · product %d",
                       typ.codePage, typ.familyID, typ.productID))
        CLILog.line("  " + t("%d polygon(s), %d line(s), %d point(s); %d of %d read exactly",
                       typ.polygons.count, typ.lines.count, typ.points.count,
                       typ.exactCount, typ.all.count))

        var dumped: [String: JSONValue] = [:]
        for kind in kinds {
            let elements = typ.elements(kind).filter {
                wantedTypes.isEmpty || wantedTypes.contains($0.code)
            }
            dumped[kind.ruleFile] = .array(elements.map { element in
                ["code": .int(element.code),
                 "hex": .string(String(format: "0x%05x", element.code)),
                 "colours": .array(element.colours.map { $0.map(JSONValue.string) ?? .null }),
                 "lineWidth": .of(element.lineWidth),
                 "borderWidth": .of(element.borderWidth),
                 "bitmapHeight": element.bitmap == nil ? .null : .int(element.bitmapHeight),
                 "hasIcon": .bool(element.dayImage != nil),
                 "exact": .bool(element.exact),
                 "labels": .array(element.labels.map {
                     ["language": .int($0.language), "text": .string($0.text)]
                 })]
            })
            guard !elements.isEmpty else { continue }
            CLILog.line("\n@@ \(kind.ruleFile)")
            for element in elements {
                var parts: [String] = [String(format: "0x%05x", element.code)]
                let colours = element.colours.map { $0 ?? "—" }
                if !colours.isEmpty { parts.append(colours.joined(separator: " ")) }
                if let width = element.lineWidth { parts.append("w\(width)") }
                if let border = element.borderWidth, border > 0 { parts.append("b\(border)") }
                if element.bitmap != nil { parts.append("\(element.bitmapHeight)px") }
                if element.dayImage != nil { parts.append("icon") }
                if !element.exact { parts.append("~") }
                // The label a TYP carries for the type, in whatever language it stores first.
                let label = element.labels.first.map { " \($0.text)" } ?? ""
                CLILog.line("  " + parts.joined(separator: "  ") + label)
            }
        }

        if all || flags.has("draw-order") {
            CLILog.line("\n@@ " + t("draw order"))
            for entry in typ.drawOrder {
                CLILog.line(String(format: "  0x%05x  level %d", entry.code, entry.level))
            }
        }
        CLIOutput.result([
            "file": .string(typURL.lastPathComponent),
            "codePage": .int(typ.codePage),
            "familyID": .int(typ.familyID),
            "productID": .int(typ.productID),
            "counts": ["polygons": .int(typ.polygons.count), "lines": .int(typ.lines.count),
                       "points": .int(typ.points.count), "exact": .int(typ.exactCount),
                       "all": .int(typ.all.count)],
            "elements": .object(dumped),
            "drawOrder": .array(typ.drawOrder.map {
                ["code": .int($0.code), "level": .int($0.level)]
            }),
        ])
        return 0
    }
}
