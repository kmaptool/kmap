import Foundation

/// Stage 6: moves the finished files into the output folder and writes the manifest.
extension BuildPipeline {
    // MARK: 6 — collect

    /// Every .img file name in the output folder's builds, except the one being written.
    ///
    /// One level deep on purpose: builds are dated folders directly under the output
    /// root, and what matters is only what would collide on a device's card.
    static func imgNames(under root: URL, excluding own: URL) -> Set<String> {
        let manager = FileManager.default
        let ownPath = own.standardizedFileURL.path
        var names = Set<String>()
        let folders = ((try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [])
        for folder in folders where folder.standardizedFileURL.path != ownPath {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true else {
                if folder.pathExtension.lowercased() == "img" {
                    names.insert(folder.lastPathComponent)
                }
                continue
            }
            for file in ((try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
            where file.pathExtension.lowercased() == "img" {
                names.insert(file.lastPathComponent)
            }
        }
        return names
    }

    func collect() async throws {
        set(.collect, .running, t("copying"))
        let destinationDir = recipe.destinationDirectory
        Paths.ensure(destinationDir)

        let buildRoot = workDirectory.appendingPathComponent("build", isDirectory: true)
        // In the packer's order, recorded by the compile stage. The directory listing is
        // the fallback for a work directory this process did not compile.
        let groups = outputGroups.isEmpty
            ? ((try? FileManager.default.contentsOfDirectory(
                at: buildRoot, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            : outputGroups.map { buildRoot.appendingPathComponent($0, isDirectory: true) }

        var written: [Output] = []
        let parts = groups
            .filter { FileTools.exists($0.appendingPathComponent("gmapsupp.img")) }

        // The file name counts ground rather than naming the region, so two different
        // maps in one style on one day would come out identical — and the second one
        // copied onto a device would silently replace the first. So the neighbouring
        // build folders are asked first, and a name already used by another build gets
        // "-2", "-3" and so on. This build's own folder is left out of the asking:
        // rebuilding the same map replaces its own files, as it always has.
        let names = Self.imgNames(under: destinationDir.deletingLastPathComponent(),
                                  excluding: destinationDir)
        let copy = recipe.freeCopy(of: parts.count) { names.contains($0) }
        if copy > 1 {
            log.step(t("another build already uses this name — files carry -%d", copy))
        }

        for (ordinal, group) in parts.enumerated() {
            let source = group.appendingPathComponent("gmapsupp.img")
            let name = recipe.fileName(ordinal: ordinal + 1, of: parts.count, copy: copy)
            let destination = destinationDir.appendingPathComponent(name)
            FileTools.removeIfPresent(destination)
            // Move rather than copy when work area and output share a volume; these files
            // run to gigabytes.
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            written.append(Output(name: name, url: destination, size: FileTools.size(of: destination)))
            log.ok("→ \(Paths.display(destination))  \(Fmt.bytes(FileTools.size(of: destination)))")
        }

        guard !written.isEmpty else { throw BuildError.noOutput(recipe.slug) }

        if recipe.customPOIs {
            await writeCustomPOIs(to: destinationDir)
        } else {
            // The output folder name does not encode the Custom POI switch, so an earlier
            // build's .gpi can be sitting here and must be removed.
            let stale = destinationDir.appendingPathComponent("\(recipe.slug).gpi")
            if FileTools.exists(stale) {
                FileTools.removeIfPresent(stale)
                log.step("removed the custom POI file left by an earlier build")
            }
        }

        try writeManifest(to: destinationDir, outputs: written)

        publish(written)
        cleanUp()
        set(.collect, .done, "\(written.count) file(s)")
    }

    /// Writes a Garmin Custom POI (`.gpi`) file beside the map, carrying every object with
    /// an OSM description; the map's own POI records have no description field.
    /// Best-effort: a failure warns and leaves the build successful.
    private func writeCustomPOIs(to directory: URL) async {
        let extract = Paths.pbfCache
            .appendingPathComponent("\(FileTools.slugify(recipe.region.id)).osm.pbf")
        guard FileTools.exists(extract) else { return }
        let destination = directory.appendingPathComponent("\(recipe.slug).gpi")

        log.step("writing custom POIs with descriptions")
        var gpi = MakeGPI(source: extract, destination: destination)
        // The same code page the map is built with, or the labels come out as `?`.
        switch recipe.codePage {
        case 1251: gpi.codepage = "cp1251"
        case 1250: gpi.codepage = "cp1250"
        case 65001: gpi.codepage = "utf8"
        default: gpi.codepage = "cp1252"
        }
        gpi.category = recipe.seriesName
        gpi.prefer = recipe.codePage == 1251 ? "ru" : "en"
        // Features hidden on the map are hidden here too.
        gpi.exclude = recipe.hidden.compactMap { HideableFeature.feature(id: $0)?.tag }.sorted()

        do {
            let report = try gpi.run()
            log.append("\(report.written) described POI(s): \(report.fromNodes) from nodes,"
                       + " \(report.fromAreas) from areas, \(report.uninformative) dropped"
                       + " as uninformative")
            log.ok("→ \(Paths.display(destination))  \(Fmt.bytes(FileTools.size(of: destination)))")
        } catch {
            log.warn("custom POIs could not be written: \(error)")
        }
    }

    /// Writes a plain-text record of the settings this map was built with, next to the
    /// `.img` files.
    private func writeManifest(to directory: URL, outputs: [Output]) throws {
        var lines: [String] = [
            "region        \(recipe.mapName)  [\(recipe.regions.map(\.id).joined(separator: ", "))]",
            "bounds        \(recipe.coverage.display)",
            "built         \(Fmt.timestamp(recipe.startedOn))",
            "style         \(recipe.style.name)",
            "family id     \(recipe.familyID)   (tile ids from \(recipe.mapIDBase))",
            "code page     \(recipe.codePage)",
            "levels        \(recipe.levels.levels)",
            "overview      \(recipe.levels.overviewLevels)",
            "contours      \(recipe.contours ? "\(recipe.contourInterval) m" : "off")",
            "DEM layer     \(recipe.demLayer ? "on" : "off")",
            "summits       \(recipe.demLayer && recipe.fixSummits ? "lifted to OSM heights" : "as measured")",
            "elevation     \(recipe.needsElevationData ? recipe.demSources : "—")",
            "routable      \(recipe.routable)",
            "search index  \(recipe.searchIndex)",
            "house numbers \(recipe.houseNumbers ? "on — address search" : "off")",
            "descriptions  \(recipe.descriptions == .off ? "off" : recipe.descriptions.label)",
            "custom POIs   \(recipe.customPOIs ? "on" : "off")",
            "files"
        ]
        for output in outputs {
            lines.append("              \(output.name)  \(Fmt.bytes(output.size))")
        }
        if let typ = recipe.style.typURL {
            lines.append("TYP           \(typ.path)")
        }
        lines.append("")
        lines.append("Copy the .img files to the Garmin folder on the device or its SD card.")
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("build-info.txt"),
            atomically: true, encoding: .utf8)
    }

    /// Removes this build's scratch directory, and the work root if it is then empty.
    /// Downloaded extracts and elevation tiles live in the cache and survive.
    private func cleanUp() {
        guard !settings.settings.keepWorkFiles else {
            log.append("work files kept in \(Paths.display(workDirectory))")
            return
        }
        let freed = directorySize(workDirectory)
        FileTools.removeIfPresent(workDirectory)

        let root = recipe.workRoot
        if let remaining = try? FileManager.default.contentsOfDirectory(
            atPath: root.path), remaining.isEmpty {
            FileTools.removeIfPresent(root)
        }
        log.ok("cleaned up work files\(freed > 0 ? " · freed \(Fmt.bytes(freed))" : "")")
    }

    func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker { total += FileTools.size(of: item) }
        return total
    }
}
