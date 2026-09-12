import Foundation

/// `kmap split`: an extract cut into tiles with kmap's own splitter, for comparison
/// against splitter.jar on the same input.
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
}
