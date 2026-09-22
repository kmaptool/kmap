import Foundation

/// `kmap split`: an extract cut into tiles with kmap's own splitter, for comparison
/// against splitter.jar on the same input.
///
///     kmap split extract.osm.pbf --output-dir tiles --mapid 63410001 \
///         --max-nodes 1600000 [--use-areas areas.list]
extension CLI {
    /// What the splitter is told when the flags say nothing: splitter.jar's own defaults,
    /// so the two can be compared on equal terms.
    private static let defaultMapID = 63410001
    private static let defaultMaxNodes = 1_600_000
    private static let defaultTileDescription = "map"

    static func split(_ arguments: [String]) -> Int32 {
        let flags = Flags(
            arguments,
            valued: ["output-dir", "mapid", "max-nodes", "description", "use-areas"]
        )
        guard let input = flags.positionals.first, let outputDir = flags.value("output-dir") else {
            return CLIOutput.refuse(
                "usage: kmap split <extract.osm.pbf> --output-dir <dir> [--mapid N]"
                    + " [--max-nodes N] [--description S] [--use-areas areas.list]"
            )
        }
        var areas: [TileSplitter.Area]?
        if let list = flags.value("use-areas") {
            guard let text = try? String(contentsOfFile: list, encoding: .utf8) else {
                return CLIOutput.failure("cannot read \(list)")
            }
            let parsed = parseAreas(text)
            guard !parsed.isEmpty else {
                return CLIOutput.failure("no areas in \(list)")
            }
            areas = parsed
        }
        let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        Paths.ensure(outputURL)
        let splitter = TileSplitter(
            options: .init(
                inputs: [URL(fileURLWithPath: input)],
                outputDirectory: outputURL,
                mapID: flags.int("mapid") ?? defaultMapID,
                maxNodes: flags.int("max-nodes") ?? defaultMaxNodes,
                description: flags.value("description") ?? defaultTileDescription,
                areas: areas
            )
        ) { CLILog.line($0) }
        do {
            let started = Date()
            let result = try splitter.run()
            for tile in result.tiles {
                let a = tile.area
                CLILog.line(
                    String(
                        format: "%@  %.4f..%.4f / %.4f..%.4f  %d node(s)",
                        tile.mapID,
                        TileSplitter.degrees(a.minLat),
                        TileSplitter.degrees(a.maxLat),
                        TileSplitter.degrees(a.minLon),
                        TileSplitter.degrees(a.maxLon),
                        tile.nodes
                    )
                )
            }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(String(format: "split in %.1f s", seconds))
            CLIOutput.result([
                "outputDir": .string(outputDir),
                "tiles": .array(
                    result.tiles.map { tile in
                        [
                            "mapID": .string(tile.mapID), "nodes": .int(tile.nodes),
                            "minLat": .double(TileSplitter.degrees(tile.area.minLat)),
                            "minLon": .double(TileSplitter.degrees(tile.area.minLon)),
                            "maxLat": .double(TileSplitter.degrees(tile.area.maxLat)),
                            "maxLon": .double(TileSplitter.degrees(tile.area.maxLon))
                        ]
                    }
                ),
                "seconds": .double(seconds)
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// An areas.list as splitter.jar writes it, one `id: lat,lon to lat,lon` per line in
    /// map units; comments and lines that do not parse are skipped.
    static func parseAreas(_ text: String) -> [TileSplitter.Area] {
        var parsed: [TileSplitter.Area] = []
        for line in text.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.hasPrefix("#"), let colon = row.firstIndex(of: ":") else { continue }
            let corners = row[row.index(after: colon)...].components(separatedBy: " to ")
            guard corners.count == 2 else { continue }
            let a = corners[0].split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            let b = corners[1].split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            guard a.count == 2, b.count == 2 else { continue }
            parsed.append(TileSplitter.Area(minLat: a[0], minLon: a[1], maxLat: b[0], maxLon: b[1]))
        }
        return parsed
    }
}
