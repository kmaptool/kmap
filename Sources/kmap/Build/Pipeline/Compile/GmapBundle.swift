import Foundation

/// The BaseCamp folder: the same tiles as the card files, in the layout the desktop
/// programs read from the computer with no device attached.
extension BuildPipeline {
    /// Writes every tile into one `.gmap` folder and returns it. A folder has no FAT32
    /// limit, so the tiles are never grouped.
    ///
    /// mkgmap unpacks each tile into its subfiles, builds the overview from the `ovm_`
    /// files the compile left beside the tiles, rebuilds the index and copies the TYP in.
    /// The compiled overview is not handed over: it would be listed as one more tile.
    func writeGmap(
        _ tiles: [Weighed],
        java: JavaRuntime,
        mkgmap: URL,
        typ: URL?
    ) async throws -> URL {
        let outDir =
            workDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("gmap", isDirectory: true)
        FileTools.removeIfPresent(outDir)
        Paths.ensure(outDir)

        let arguments = combineArguments(
            java: java,
            mkgmap: mkgmap,
            mode: "--gmapi",
            areaName: recipe.slug,
            outputDir: outDir,
            options: gmapOptions(),
            inputs: tiles.map(\.url),
            typ: typ
        )

        log.step("writing the BaseCamp folder — \(tiles.count) tile(s)")
        let runner = makeRunner()
        try await runner.run(java.path, arguments, cwd: outDir) { line in
            self.log.output(line, stage: StageID.compile.rawValue)
            self.detail(.compile, "gmap: writing", fraction: 0.95)
        }

        guard let bundle = Self.gmapFolder(in: outDir) else { throw BuildError.noGmap }
        log.ok("gmap: \(Fmt.bytes(directorySize(bundle)))")
        return bundle
    }

    /// What the gmapi run needs beyond the identity: the overview's name and number, the
    /// flag that lets BaseCamp draw an elevation profile, and relief for the overview
    /// alone, since the tiles carry theirs already.
    func gmapOptions() -> [String] {
        var options = [
            "--overview-mapname=\(recipe.overviewMapID)",
            "--overview-mapnumber=\(recipe.overviewMapID)",
            "--show-profiles=1"
        ]
        if recipe.demLayer {
            let cells = stageDEMCells()
            if !cells.isEmpty {
                options.append("--dem=" + cells.map(\.path).joined(separator: ","))
                options.append("--overview-dem-dist=\(Self.overviewDEMDistance)")
            }
        }
        return options
    }

    /// The `.gmap` folder mkgmap wrote under `outDir`: beside the index files today, in a
    /// `.gmapi` wrapper in other releases.
    static func gmapFolder(in outDir: URL) -> URL? {
        func folders(in dir: URL) -> [URL] { FileTools.contents(of: dir).filter(FileTools.isDirectory) }
        func gmap(among urls: [URL]) -> URL? { urls.first { $0.pathExtension.lowercased() == "gmap" } }
        let top = folders(in: outDir)
        return gmap(among: top) ?? top.lazy.compactMap { gmap(among: folders(in: $0)) }.first
    }
}
