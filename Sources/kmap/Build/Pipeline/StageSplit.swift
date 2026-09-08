import Foundation

/// Stage 4: annotates each extract and cuts it into tiles. The annotation pass runs here
/// because its output is what gets split: barrier classes, repaired road ends, tidied
/// descriptions and the contours, all in the one file the splitter is handed.
extension BuildPipeline {
    // MARK: 4 — split

    struct TileSet {
        let directory: URL
        let tiles: [Tile]
        /// The cap this set was split at, so an overflow can say what to come down from.
        let nodeCap: Int
    }

    struct Tile {
        let mapID: String
        let argsBlock: String
        let bbox: BBox
        let inputSize: Int64
    }

    func splitIntoTiles(extracts: [URL], contours contoursTask: Task<[URL], Error>,
                                maxNodes: Int,
                                areas: [TileSplitter.Area]? = nil) async throws -> TileSet {
        set(.split, .running, t("starting"))

        let tileDir = workDirectory.appendingPathComponent("tiles", isDirectory: true)
        FileTools.removeIfPresent(tileDir)
        Paths.ensure(tileDir)

        // Contours travel inside the first extract rather than beside it, so they are kept
        // complete across tile borders. Each extract is annotated separately.
        var inputs: [String] = []
        try await measure(.split, "classify and repair") {
            inputs = try await annotateExtracts(extracts, contoursTask: contoursTask)
        }

        log.step("splitting into tiles (\(inputs.count) input file(s))")

        // Logged because the effect of either overlap is visible only on a receiver.
        if toolchain.mkgmapIsPatched {
            log.step("seam patch on · overlap \(recipe.shapeOverlap) units"
                     + " · land \(min(recipe.landOverlap, recipe.shapeOverlap)) units")
        }
        // Tile ids must be unique across every map on the receiver: two maps sharing tile
        // ids hide each other.
        let splitter = TileSplitter(options: .init(
            inputs: inputs.map { URL(fileURLWithPath: $0) },
            outputDirectory: tileDir,
            mapID: recipe.mapIDBase,
            maxNodes: maxNodes,
            leastTiles: Machine.cores,
            // The header slot, not the map's name: splitter writes it into every tile's
            // args and mkgmap puts it into the .img header, which holds 50 characters.
            description: recipe.headerDescription,
            areas: areas,
            // Only a patched mkgmap draws past the tile frame; without the patch the band
            // would swell every tile with ground no compiler reads.
            shapeOverlap: toolchain.mkgmapIsPatched ? Int32(recipe.shapeOverlap) : 0))
        { [weak self] line in
            self?.log.output(line, stage: StageID.split.rawValue)
            self?.detail(.split, line)
        }
        // The stage's bar: annotation took the first share, the splitter's phase
        // boundaries walk the rest.
        splitter.progress = { [weak self] fraction in
            self?.advance(.split, fraction: Self.splitAnnotateShare
                          + (1 - Self.splitAnnotateShare) * fraction)
        }
        let result = try await measure(.split, "cut the tiles") { try splitter.run() }
        try Task.checkCancellation()
        // One line per tile: the shape of the cut, which matters when a build is being
        // argued with rather than watched.
        for tile in result.tiles {
            log.debug("\(tile.mapID): \(tile.nodes) node(s)", stage: StageID.split.rawValue,
                      fields: ["mapID": .string("\(tile.mapID)"), "nodes": .int(tile.nodes)])
        }

        let tiles = try parseTiles(in: tileDir)
        guard !tiles.isEmpty else { throw BuildError.noTiles }
        log.ok("\(tiles.count) tile(s)")
        set(.split, .done, "\(tiles.count) tile(s)")
        return TileSet(directory: tileDir, tiles: tiles, nodeCap: maxNodes)
    }

    private func parseTiles(in directory: URL) throws -> [Tile] {
        let argsURL = directory.appendingPathComponent("template.args")
        guard let argsText = try? String(contentsOf: argsURL, encoding: .utf8) else {
            throw BuildError.splitterOutput("template.args was not produced")
        }

        let bounds = parseAreasList(directory.appendingPathComponent("areas.list"))

        // template.args is a sequence of blocks, each introduced by `mapname:`.
        var tiles: [Tile] = []
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else { return }
            guard let mapID = currentLines
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("mapname:") })?
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) else {
                currentLines = []
                return
            }

            // splitter writes `input-file:` relative to its own output directory; the
            // per-group args files live elsewhere, so the paths are made absolute.
            var input: String?
            let rewritten = currentLines.map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("input-file:"),
                      let value = trimmed.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces),
                      !value.hasPrefix("/") else { return line }
                input = value
                return "input-file: \(directory.appendingPathComponent(value).path)"
            }

            let size = input.map { FileTools.size(of: directory.appendingPathComponent($0)) } ?? 0
            tiles.append(Tile(mapID: mapID,
                              argsBlock: rewritten.joined(separator: "\n"),
                              bbox: bounds[mapID] ?? .empty,
                              inputSize: size))
            currentLines = []
        }

        for rawLine in argsText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("mapname:") { flush() }
            currentLines.append(line)
        }
        flush()

        return tiles
    }

    /// Reads `areas.list`, which pairs each tile id with its bounds. The degree values are
    /// in a comment line directly beneath the map-unit line.
    private func parseAreasList(_ url: URL) -> [String: BBox] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: BBox] = [:]
        var pendingID: String?

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                // Comment line: `#	: <minLat>,<minLon> to <maxLat>,<maxLon>`
                guard let id = pendingID,
                      let colon = line.firstIndex(of: ":") else { continue }
                let body = line[line.index(after: colon)...]
                let corners = body.components(separatedBy: " to ")
                guard corners.count == 2 else { continue }
                let a = corners[0].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let b = corners[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard a.count == 2, b.count == 2 else { continue }
                var box = BBox.empty
                box.extend(lon: a[1], lat: a[0])
                box.extend(lon: b[1], lat: b[0])
                result[id] = box
                pendingID = nil
            } else if let colon = line.firstIndex(of: ":") {
                let id = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty, id.allSatisfy(\.isNumber) { pendingID = id }
            }
        }
        return result
    }
}
