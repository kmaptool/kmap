import Foundation

/// Packing the compiled tiles into output files: weighing them, laying the groups
/// so each fits its card, and one gmapsupp per group. The BaseCamp folder is GmapBundle.
extension BuildPipeline {
    /// The largest file FAT32 can hold, which is the card format a receiver reads.
    private static let fatFileLimit: Int64 = 4_294_967_295

    /// Puts the compiled tiles into the outputs the format asks for. Nothing is compiled
    /// twice: the `.img` files go in as they are; only the index and the overview are
    /// rebuilt. Returns how many outputs were written, the BaseCamp folder counting as one.
    func bundle(
        _ tiles: [Tile],
        from tileDir: URL,
        java: JavaRuntime,
        mkgmap: URL,
        typ: URL?
    ) async throws -> Int {
        var weighed: [Weighed] = []
        for tile in tiles {
            let url = tileDir.appendingPathComponent("\(tile.mapID).img")
            guard FileTools.exists(url) else { throw BuildError.noOutput(tile.mapID) }
            guard ImgContainer.isWhole(url) else { throw BuildError.cutShort(url.lastPathComponent) }
            weighed.append(Weighed(tile: tile, url: url, size: FileTools.size(of: url)))
        }
        let total = weighed.reduce(Int64(0)) { $0 + $1.size }
        log.append("compiled \(Fmt.bytes(total)) of tiles")

        let cards = recipe.format.writesCardFiles, gmap = recipe.format.writesGmap
        let course = ProgressCourse<Bundled>([
            (.cardFiles, cards ? Double(total) : 0), (.gmap, gmap ? Double(total) : 0)
        ])
        let files = self.report(.compile).part(CompileStep.files, of: CompileStep.course)
        func report(_ part: Bundled) -> ProgressReport { files.part(part, of: course) }

        var written = 0
        if cards {
            written += try await writeCardFiles(
                weighed,
                java: java,
                mkgmap: mkgmap,
                typ: typ,
                report: report(.cardFiles)
            )
        }
        if gmap {
            gmapBundle = try await writeGmap(weighed, java: java, mkgmap: mkgmap, typ: typ, report: report(.gmap))
            written += 1
        }
        return written
    }

    private enum Bundled: Sendable {
        case cardFiles, gmap
    }

    /// Runs mkgmap, reporting inputs taken in and the output's growth.
    func writingOutput(
        _ java: JavaRuntime,
        _ arguments: [String],
        in directory: URL,
        inputs: [URL],
        growing output: @escaping @Sendable () -> Int64,
        towards expected: Int64,
        takingIn: ProgressReport,
        writing: ProgressReport
    ) async throws {
        MkgmapFiles.clear(in: directory)
        defer { MkgmapFiles.clear(in: directory) }
        let mentions = Double(max(1, MkgmapFiles.mentions(of: inputs)))
        let watcher = Task {
            while !Task.isCancelled {
                let named = MkgmapFiles.named(by: directory)
                if named > 0 { takingIn(Double(named) / mentions) }
                let written = Double(output()) / Double(max(1, expected))
                if written > 0 { writing(written) }
                try? await Task.sleep(nanoseconds: Self.watchTick)
            }
        }
        defer { watcher.cancel() }
        try await makeRunner().run(java.path, arguments, cwd: directory) { line in
            self.log.output(line, stage: StageID.compile.rawValue)
        }
    }

    /// The `.img` files, as few as the split mode allows.
    private func writeCardFiles(
        _ weighed: [Weighed],
        java: JavaRuntime,
        mkgmap: URL,
        typ: URL?,
        report: ProgressReport
    ) async throws -> Int {
        // The index and the container directory are written on top of the tiles, so groups
        // are filled short of the limit and the result checked; the margin widens on retry.
        var headroom = 0.85
        while true {
            let packer = TilePacker(
                mode: recipe.splitMode,
                axis: SplitAxis.best(for: recipe.coverage),
                slug: recipe.areaSlug,
                regions: recipe.regions,
                countryOf: recipe.countryOf
            )
            let groups = packer.groups(
                weighed.map {
                    TilePacker.Tile(id: $0.tile.mapID, bbox: $0.tile.bbox, bytes: $0.size)
                },
                upTo: Int64(Double(Self.fatFileLimit) * headroom)
            )
            var oversized: [String] = []
            let course = ProgressCourse(
                weights: groups.map { group in
                    Double(group.members.reduce(Int64(0)) { $0 + weighed[$1].size })
                }
            )
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                let size = try await write(
                    group: group.members.map { weighed[$0] },
                    named: group.name,
                    java: java,
                    mkgmap: mkgmap,
                    typ: typ,
                    report: report.part(index, of: course)
                )
                if size >= Self.fatFileLimit { oversized.append(group.name) }
            }
            outputGroups = groups.map(\.name)
            if oversized.isEmpty { return groups.count }
            // A count of files is cut by weight, not by the limit: more room changes nothing.
            var fixedCount = false
            if case .count = recipe.splitMode { fixedCount = true }
            guard headroom > 0.5, !fixedCount else {
                // Out of headroom: the split mode asked for groups this big.
                log.warn(
                    "\(oversized.joined(separator: ", ")) exceed(s) FAT32's 4 GB"
                        + " — the file(s) will not copy onto a card; use --parts or"
                        + " --split=fit to cut smaller"
                )
                return groups.count
            }
            headroom -= 0.15
            log.warn(
                "\(oversized.joined(separator: ", ")) came out past FAT32's limit"
                    + " — packing again with more room for the index"
            )
        }
    }

    /// One gmapsupp for one group of tiles, rebuilt index included.
    func write(
        group: [Weighed],
        named name: String,
        java: JavaRuntime,
        mkgmap: URL,
        typ: URL?,
        report: ProgressReport
    ) async throws -> Int64 {
        let outDir =
            workDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        FileTools.removeIfPresent(outDir)
        Paths.ensure(outDir)

        // mkgmap builds an overview map of the whole compile at the coarsest levels. It is
        // bundled in, so the far zooms read one small map instead of every tile's top level.
        let overview = tileDir(of: group)
            .appendingPathComponent("\(recipe.overviewMapID).img")
        let inputs = group.map(\.url) + (try overviewIfAny(overview))

        let arguments = combineArguments(
            java: java,
            mkgmap: mkgmap,
            mode: "--gmapsupp",
            areaName: name,
            outputDir: outDir,
            inputs: inputs,
            typ: typ
        )

        let course = OutputStep.course(indexing: recipe.searchIndex)
        log.step("writing \(name) — \(group.count) tile(s)")
        detail(.compile, "\(name): writing")
        let produced = outDir.appendingPathComponent("gmapsupp.img")
        try await writingOutput(
            java,
            arguments,
            in: outDir,
            inputs: combineInputs(inputs, typ: typ),
            growing: { FileTools.size(of: produced) },
            towards: group.reduce(Int64(0)) { $0 + $1.size },
            takingIn: report.part(.takeIn, of: course),
            writing: report.part(.write, of: course)
        )

        guard FileTools.exists(produced) else { throw BuildError.noOutput(name) }
        guard ImgContainer.isWhole(produced) else { throw BuildError.cutShort(name) }
        let size = FileTools.size(of: produced)
        log.ok("\(name): \(Fmt.bytes(size))")
        return size
    }

    private func overviewIfAny(_ overview: URL) throws -> [URL] {
        guard FileTools.exists(overview) else { return [] }
        guard ImgContainer.isWhole(overview) else { throw BuildError.cutShort(overview.lastPathComponent) }
        return [overview]
    }

    private func tileDir(of group: [Weighed]) -> URL {
        group.first?.url.deletingLastPathComponent()
            ?? workDirectory.appendingPathComponent("build/tiles", isDirectory: true)
    }
}
