import Foundation

/// Stage 6: moves the finished files into the output folder and writes the manifest.
extension BuildPipeline {
    // MARK: 6 - collect

    /// The extensions an output carries: a card file, and the BaseCamp folder.
    private static let outputExtensions: Set<String> = ["img", "gmap"]

    /// Every output name in the output folder's builds, except the one being written.
    /// One level deep on purpose: builds are dated folders directly under the output root.
    static func outputNames(under root: URL, excluding own: URL) -> Set<String> {
        let manager = FileManager.default
        let ownPath = own.standardizedFileURL.path
        var names = Set<String>()
        func isOutput(_ url: URL) -> Bool {
            outputExtensions.contains(url.pathExtension.lowercased())
        }
        let folders =
            ((try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
        for folder in folders where folder.standardizedFileURL.path != ownPath {
            if isOutput(folder) {
                names.insert(folder.lastPathComponent)
                continue
            }
            guard FileTools.isDirectoryItself(folder) else { continue }
            for file
                in ((try? manager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? [])
            where isOutput(file) {
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
        // In the packer's order, recorded by the compile stage. Only these: a group folder
        // an earlier build left in the work directory is not this map.
        let groups = outputGroups.map { buildRoot.appendingPathComponent($0, isDirectory: true) }

        let parts =
            groups
            .filter { FileTools.exists($0.appendingPathComponent("gmapsupp.img")) }

        // The name carries the regions and the day only, so a second build of the same
        // ground that day would replace the first on a card: a name another build folder
        // already uses gets "-2", "-3". This build's own folder is left out, so a rebuild
        // replaces its own files.
        let names = Self.outputNames(
            under: destinationDir.deletingLastPathComponent(),
            excluding: destinationDir
        )
        let gmap = gmapBundle
        let copy = recipe.freeCopy(of: parts.count, gmap: gmap != nil) { names.contains($0) }
        if copy > 1 {
            log.step(t("another build already uses this name — files carry -%d", copy))
        }

        var outputs: [(source: URL, destination: URL)] = parts.enumerated().map { ordinal, group in
            let name = recipe.fileName(ordinal: ordinal + 1, of: parts.count, copy: copy)
            return (group.appendingPathComponent("gmapsupp.img"), destinationDir.appendingPathComponent(name))
        }
        if let gmap {
            outputs.append(
                (gmap, destinationDir.appendingPathComponent(recipe.gmapName(copy: copy), isDirectory: true))
            )
        }
        let written = try place(outputs)
        if gmap != nil {
            log.append(
                "BaseCamp tells maps apart by family id: another kmap map installed with id"
                    + " \(recipe.familyID) replaces this one there"
            )
        }

        guard !written.isEmpty else { throw BuildError.noOutput(recipe.areaSlug) }
        removeEarlierOutputs(in: destinationDir, keeping: written)

        if recipe.customPOIs {
            await writeCustomPOIs(to: destinationDir)
        } else {
            // The output folder name does not encode the Custom POI switch, so an earlier
            // build's .gpi can be sitting here and must be removed.
            let stale = destinationDir.appendingPathComponent("\(recipe.areaSlug).gpi")
            if FileTools.exists(stale) {
                FileTools.removeIfPresent(stale)
                log.step("removed the custom POI file left by an earlier build")
            }
        }

        // The maps are in place by now: a record that will not write does not undo them.
        do {
            try writeManifest(to: destinationDir, outputs: written)
        } catch {
            log.warn("build-info.txt could not be written: \(ErrorWords.of(error))")
        }

        publish(written)
        cleanUp()
        set(.collect, .done, "\(written.count) file(s)")
    }

    /// Puts the finished outputs, files or folders, in their places, all or none: a set
    /// with a part new and the next old would show both maps on a receiver. Moved
    /// rather than copied where work area and output share a volume: these run to
    /// gigabytes.
    func place(_ outputs: [(source: URL, destination: URL)]) throws -> [Output] {
        // Under another name until whole, so a copy that fails midway leaves the earlier
        // files in place and no part of the new ones under their names.
        var staged: [(source: URL, partial: URL, moved: Bool)] = []
        // A moved partial is the only copy of the new map: it goes back, or stays and is
        // said to, until a build into the same folder lands or the user removes it.
        func unstage() {
            for item in staged {
                guard item.moved else {
                    FileTools.removeIfPresent(item.partial)
                    continue
                }
                if (try? FileTools.move(item.partial, to: item.source)) == nil, FileTools.exists(item.partial) {
                    log.warn("the new map stays in \(Paths.display(item.partial))")
                }
            }
        }
        for output in outputs {
            let partial = Self.leftover(of: output.destination, ".partial")
            FileTools.removeIfPresent(partial)
            do {
                try FileTools.move(output.source, to: partial)
                staged.append((output.source, partial, true))
            } catch {
                FileTools.removeIfPresent(partial)
                do {
                    try FileTools.copy(output.source, to: partial)
                    staged.append((output.source, partial, false))
                } catch {
                    FileTools.removeIfPresent(partial)
                    unstage()
                    throw error
                }
            }
        }
        // A BaseCamp folder held open stays whole, with the new map not put in.
        do {
            try FileTools.replace(zip(outputs, staged).map { ($0.destination, $1.partial) })
        } catch {
            unstage()
            throw error
        }
        return outputs.map { output in
            let destination = output.destination
            let size = FileTools.isDirectory(destination) ? directorySize(destination) : FileTools.size(of: destination)
            log.ok("→ \(Paths.display(destination))  \(Fmt.bytes(size))")
            return Output(name: destination.lastPathComponent, url: destination, size: size)
        }
    }

    /// The suffixes an output wears on its way in, and an earlier one on its way out; see
    /// `FileTools.replace`.
    static let leftoverSuffixes = [".partial", ".old"]

    static func leftover(of output: URL, _ suffix: String) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + suffix)
    }

    /// Removes this map's earlier files this build did not replace, which a receiver would
    /// show beside the new set, and what a stopped build left under `leftoverSuffixes`.
    func removeEarlierOutputs(in directory: URL, keeping written: [Output]) {
        let kept = Set(written.map(\.name))
        let entries =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let suffix = Self.leftoverSuffixes.first { name.hasSuffix($0) }
            let output = suffix.map { String(name.dropLast($0.count)) } ?? name
            guard recipe.namesAnOutput(output), suffix != nil || !kept.contains(name) else { continue }
            guard (try? FileTools.remove(entry)) != nil else {
                log.warn("could not remove \(Paths.display(entry)), left by an earlier build")
                continue
            }
            if suffix == nil { removed += 1 }
        }
        if removed > 0 { log.step("removed \(removed) map file(s) left by an earlier build") }
    }

    /// Writes a Garmin Custom POI (`.gpi`) file beside the map, carrying every object with
    /// an OSM description; the map's own POI records have no description field.
    /// Best-effort: a failure warns and leaves the build successful.
    private func writeCustomPOIs(to directory: URL) async {
        // Every region of a joined map, not the first alone, as this build read them.
        let extracts = recipe.regions.map { region in
            let cached = Paths.cachedExtract(forRegion: region.id)
            let pinned = pinnedExtract(cached)
            return FileTools.exists(pinned) ? pinned : cached
        }
        .filter(FileTools.exists)
        guard !extracts.isEmpty else { return }
        let destination = directory.appendingPathComponent("\(recipe.areaSlug).gpi")
        // An earlier build's file is not this map's, whether or not a new one is written.
        FileTools.removeIfPresent(destination)

        log.step("writing custom POIs with descriptions")
        var gpi = MakeGPI(sources: extracts, destination: destination)
        // The same code page the map is built with, or the labels come out as `?`.
        gpi.codepage = recipe.codePage == CodePage.utf8 ? "utf8" : "cp\(recipe.codePage)"
        gpi.category = recipe.seriesName
        gpi.prefer = recipe.speaksRussian ? "ru" : "en"
        // Features hidden on the map are hidden here too.
        gpi.exclude = recipe.hidden.compactMap { HideableFeature.feature(id: $0)?.tag }.sorted()
        gpi.shouldStop = stopAsked

        do {
            let report = try gpi.run()
            log.append(
                "\(report.written) described POI(s): \(report.fromNodes) from nodes,"
                    + " \(report.fromAreas) from areas, \(report.uninformative) dropped"
                    + " as uninformative"
            )
            log.ok("→ \(Paths.display(destination))  \(Fmt.bytes(FileTools.size(of: destination)))")
        } catch is CancellationError {
            log.warn("custom POIs left out: the build was stopped once its maps were in place")
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
            "version       \(recipe.productVersionLabel)   (the build month)",
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
            "format        \(recipe.format.rawValue)",
            "files"
        ]
        for output in outputs {
            lines.append("              \(output.name)  \(Fmt.bytes(output.size))")
        }
        if let typ = recipe.style.typURL {
            lines.append("TYP           \(typ.path)")
        }
        lines.append("")
        if recipe.format.writesCardFiles {
            lines.append("Copy the .img files to the Garmin folder on the device or its SD card.")
        }
        if recipe.format.writesGmap {
            lines.append(
                "Put the .gmap folder where BaseCamp looks for installed maps and start it again:"
                    + " ~/Library/Application Support/Garmin/Maps on macOS (or open the folder"
                    + " with Garmin MapManager), %ProgramData%\\Garmin\\Maps on Windows."
                    + " No device is needed."
            )
        }
        try FileTools.write(lines.joined(separator: "\n"), to: directory.appendingPathComponent("build-info.txt"))
    }

    /// Removes this build's scratch directory, or marks it kept so no sweep takes it.
    /// Downloaded extracts and elevation tiles live in the cache and survive.
    private func cleanUp() {
        guard !settings.settings.keepWorkFiles else {
            try? FileTools.write("", to: workDirectory.appendingPathComponent(Self.keptMarker))
            log.append("work files kept in \(Paths.display(workDirectory))")
            return
        }
        let freed = directorySize(workDirectory)
        FileTools.removeIfPresent(workDirectory)
        log.ok("cleaned up work files\(freed > 0 ? " · freed \(Fmt.bytes(freed))" : "")")
    }

    func directorySize(_ url: URL) -> Int64 {
        guard
            let walker = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker { total += FileTools.size(of: item) }
        return total
    }
}
