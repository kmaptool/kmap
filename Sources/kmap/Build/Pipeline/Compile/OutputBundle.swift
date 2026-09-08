import Foundation

/// Packing the compiled tiles into output files: weighing them, laying the groups
/// so each fits its card, and one gmapsupp per group.
extension BuildPipeline {
    /// The largest file FAT32 can hold, which is the card format a receiver reads.
    private static let fatFileLimit: Int64 = 4_294_967_295

    /// One compiled tile, with what it weighs.
    struct Weighed {
        let tile: Tile
        let url: URL
        let size: Int64
    }

    /// Puts the compiled tiles into output files, as few as the split mode allows. Nothing
    /// is compiled twice: the `.img` files go in as they are and only the search index is
    /// rebuilt from them.
    func bundle(_ tiles: [Tile], from tileDir: URL,
                        java: JavaRuntime, mkgmap: URL, typ: URL?) async throws -> Int {
        var weighed: [Weighed] = []
        for tile in tiles {
            let url = tileDir.appendingPathComponent("\(tile.mapID).img")
            guard FileTools.exists(url) else { throw BuildError.noOutput(tile.mapID) }
            weighed.append(Weighed(tile: tile, url: url, size: FileTools.size(of: url)))
        }
        let total = weighed.reduce(Int64(0)) { $0 + $1.size }
        log.append("compiled \(Fmt.bytes(total)) of tiles")

        // The index and the container directory are written on top of the tiles, so groups
        // are filled short of the limit and the result checked; the margin widens on retry.
        var headroom = 0.85
        while true {
            let packer = TilePacker(mode: recipe.splitMode,
                                    axis: SplitAxis.best(for: recipe.coverage),
                                    slug: recipe.slug, regions: recipe.regions,
                                    countryOf: recipe.countryOf)
            let groups = packer.groups(weighed.map {
                TilePacker.Tile(id: $0.tile.mapID, bbox: $0.tile.bbox, bytes: $0.size)
            }, upTo: Int64(Double(Self.fatFileLimit) * headroom))
            var oversized: [String] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                let size = try await write(group: group.members.map { weighed[$0] },
                                           named: group.name,
                                           java: java, mkgmap: mkgmap, typ: typ,
                                           progress: (index, groups.count))
                if size >= Self.fatFileLimit { oversized.append(group.name) }
            }
            outputGroups = groups.map(\.name)
            if oversized.isEmpty { return groups.count }
            guard headroom > 0.5 else {
                // Out of headroom: the split mode asked for groups this big.
                log.warn("\(oversized.joined(separator: ", ")) exceed(s) FAT32's 4 GB"
                         + " — the file(s) will not copy onto a card; use --parts or"
                         + " --split=fit to cut smaller")
                return groups.count
            }
            headroom -= 0.15
            log.warn("\(oversized.joined(separator: ", ")) came out past FAT32's limit"
                     + " — packing again with more room for the index")
        }
    }

    /// One gmapsupp for one group of tiles, rebuilt index included.
    func write(group: [Weighed], named name: String, java: JavaRuntime, mkgmap: URL,
                       typ: URL?,
                       progress: (index: Int, of: Int)) async throws -> Int64 {
        let outDir = workDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        FileTools.removeIfPresent(outDir)
        Paths.ensure(outDir)

        // mkgmap builds an overview map of the whole compile at the coarsest levels. It is
        // bundled in, so the far zooms read one small map instead of every tile's top level.
        let overview = tileDir(of: group)
            .appendingPathComponent("\(recipe.overviewMapID).img")

        var arguments = java.command(["-Xmx\(recipe.heapGB)g", "-jar", mkgmap.path,
                                      "--gmapsupp"]
                                     + identityOptions(areaName: name)
                                     + ["--output-dir=\(outDir.path)"])
        arguments += indexOptions()
        arguments += copyrightOption()
        arguments += group.map(\.url.path)
        if FileTools.exists(overview) { arguments.append(overview.path) }
        if let typ, FileTools.exists(typ) {
            arguments.append(typ.path)
        }

        log.step("writing \(name) — \(group.count) tile(s)")
        let runner = makeRunner()
        try await runner.run(java.path, arguments, cwd: outDir) { line in
            self.log.output(line, stage: StageID.compile.rawValue)
            self.detail(.compile, "\(name): writing",
                        fraction: 0.9 + 0.1 * Double(progress.index) / Double(max(1, progress.of)))
        }

        let produced = outDir.appendingPathComponent("gmapsupp.img")
        guard FileTools.exists(produced) else { throw BuildError.noOutput(name) }
        let size = FileTools.size(of: produced)
        log.ok("\(name): \(Fmt.bytes(size))")
        return size
    }


    private func tileDir(of group: [Weighed]) -> URL {
        group.first?.url.deletingLastPathComponent()
            ?? workDirectory.appendingPathComponent("build/tiles", isDirectory: true)
    }

}
