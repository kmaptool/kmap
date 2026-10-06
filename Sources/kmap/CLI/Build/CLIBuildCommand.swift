import Foundation

/// `kmap build`: the whole pipeline from one command line. Every flag the interactive form
/// offers has an equivalent here. The order is fixed: read the profile, let the flags
/// override it, refuse everything wrong at once, then hand a recipe to the pipeline.
extension CLI {
    static func regionRefusal(_ flags: Flags, arguments: [String]) -> String? {
        guard flags.positionals.count != 1 else { return nil }
        guard let second = flags.positionals.dropFirst().first else {
            return "build needs a region id, e.g. austria"
        }
        // A mistyped option leaves its value standing alone, where it reads as a region.
        let unknown = unknownBuildOptions(in: flags)
        guard unknown.isEmpty else {
            return unknown.map { "--\($0) is not an option of `kmap build` — see `kmap help`" }
                .joined(separator: "; ")
        }
        // A value given after a space to an `=`-only option, before or after the region.
        for (at, word) in arguments.enumerated().dropFirst() where flags.positionals.contains(word) {
            let before = arguments[at - 1]
            if valuedOnlyAfterEquals.map({ "--" + $0 }).contains(before) {
                return "\"\(word)\" follows \(before), which takes a value only after =,"
                    + " as \(before)=\(word); several regions are joined with +"
            }
        }
        return "build takes one region id, and \"\(second)\" is a second;"
            + " several regions are joined with +, e.g. austria+germany"
    }

    static func build(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: buildValuedOptions)
        if let refusal = regionRefusal(flags, arguments: arguments) { return CLIOutput.refuse(refusal) }
        let regionID = flags.positionals[0]

        // Flags apply to this run only: a one-off `--out=` must not become the stored
        // output folder.
        let store = SettingsStore()
        store.overrideForRun { settings in
            if flags.has("keep-work") { settings.keepWorkFiles = true }
            if let out = flags.value("out") { settings.outputDirectory = out }
            if let work = flags.value("work") { settings.workDirectory = work }
        }
        let settings = store.settings
        let toolchain = Toolchain(settings: store)
        let catalog = StyleCatalog(settings: store, toolchain: toolchain)

        guard let choices = chosenChoices(flags.value("profile"), in: store) else {
            return CLIOutput.refuse("no profile called \"\(flags.value("profile") ?? "")\" — see `kmap profiles`")
        }

        var asked = BuildOptions(flags)
        for name in unknownBuildOptions(in: flags) {
            asked.refused.append("--\(name) is not an option of `kmap build` — see `kmap help`")
        }
        if let sources = flags.value("sources") {
            let unknown = unknownSources(in: sources)
            if !unknown.isEmpty || CopernicusDEM.canonicalSourceList(sources).isEmpty {
                asked.refused.append(
                    "--sources: "
                        + (unknown.isEmpty
                            ? "the list is empty" : "no source called \(unknown.joined(separator: ", "))")
                        + " — copernicus1, copernicus3, fabdem1, gedtm1, view1, view3, srtm1, srtm3 or alos1"
                )
            }
        }
        let heap = asked.number("heap", in: BuildOptions.heapGB)
        let connections = asked.number("connections", in: BuildOptions.connections)
        if let memory = asked.number("memory", in: BuildOptions.memoryGB) { Machine.told(memory) }
        let repairRadius = asked.repairRadius()
        let style = chosenStyle(&asked, choices: choices, catalog: catalog)
        let hidden = asked.hidden() ?? choices.hiddenFeatures
        let drawn = RenderingChoices(&asked, choices: choices, settings: settings)
        let parts = asked.number("parts", in: BuildOptions.parts)
        let interval = asked.number("interval", in: BuildOptions.contourInterval) ?? choices.contourInterval
        let maxNodes = asked.number("max-nodes", in: BuildOptions.nodesPerTile) ?? settings.maxNodesPerTile
        let familyID = asked.number("family-id", in: BuildOptions.familyID)
        let split = splitMode(&asked, choices: choices, parts: parts)
        let format = outputFormat(&asked, choices: choices)
        let overlap = overlaps(&asked, choices: choices)
        guard asked.refused.isEmpty, let style, let split else { return CLIOutput.refuse(asked.refused) }

        // The network is reached only after every flag has been accepted.
        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }
        let chosen: [Region]
        switch chosenRegions(regionID, in: index) {
        case .success(let found): chosen = found
        case .failure(let refusal): return CLIOutput.refuse(refusal.why)
        }
        let region = chosen[0]

        var recipe = BuildRecipe(
            region: region,
            extraRegions: Array(chosen.dropFirst()),
            style: style,
            contours: asked.switched("contours", choices.contours),
            contourInterval: interval,
            demLayer: asked.switched("dem", choices.demLayer),
            fixSummits: asked.switched("summits", choices.fixSummits),
            demSources: CopernicusDEM.canonicalSourceList(flags.value("sources") ?? choices.demSources),
            routable: asked.switched("route", choices.routable),
            searchIndex: asked.switched("index", choices.searchIndex),
            houseNumbers: asked.switched("house-numbers", choices.houseNumbers),
            generateSea: asked.switched("sea", choices.generateSea),
            // 0 leaves the code page to the region.
            codePage: drawn.codePage != 0 ? drawn.codePage : BuildRecipe.suggestedCodePage(for: region, in: index),
            levels: drawn.levels,
            nameTagList: drawn.labels.tagList,
            descriptions: drawn.descriptions,
            zoomPlan: drawn.zoomPlan,
            customPOIs: asked.switched("custom-pois", choices.customPOIs),
            splitNameIndex: asked.wordIndex(choices.splitNameIndex),
            healRoadEnds: asked.switched("repair-ends", choices.healRoadEnds),
            hidden: Set(hidden),
            familyID: familyID ?? store.familyID(for: BuildRecipe.identityKey(chosen)),
            splitMode: split,
            countryOf: countries(of: chosen, in: index),
            outputDirectory: store.settings.outputURL,
            workRoot: store.settings.workURL,
            maxNodesPerTile: maxNodes,
            heapGB: heap ?? settings.resolvedHeapGB,
            downloadConnections: connections ?? settings.downloadConnections
        )
        recipe.healRadius = repairRadius ?? recipe.healRadius
        recipe.startedOn = Date()
        recipe.theme = drawn.theme
        recipe.format = format
        recipe.shapeOverlap = overlap.shape
        recipe.landOverlap = overlap.land

        // Said before any work starts, naming the one command that fixes it.
        guard toolchain.canBuild else {
            let missing = Toolchain.missingRequirements(in: toolchain.status()).map(\.id)
            return CLIOutput.refuse("\(missing.joined(separator: " and ")) missing — run: kmap install")
        }

        let pipeline = BuildPipeline(
            recipe: recipe,
            settings: store,
            toolchain: toolchain,
            styles: catalog,
            showing: CLIOutput.showing
        )
        // Ctrl+C cancels the pipeline, so its tools stop and the stream ends with its last
        // event; watched before the first tool can start.
        let interrupts = watchInterrupts { pipeline.cancel() }
        defer { interrupts.stop() }
        pipeline.start()
        return await follow(pipeline, landingIn: recipe.destinationDirectory)
    }

    /// The style the build was asked for, or the profile's own. An unknown style is
    /// refused rather than swapped for whichever comes first.
    private static func chosenStyle(
        _ asked: inout BuildOptions,
        choices: BuildChoices,
        catalog: StyleCatalog
    ) -> MapStyle? {
        if asked.flags.has("style") { return asked.style(in: catalog) }
        if let found = StyleCatalog.find(choices.styleID, in: catalog.availableStyles()) { return found }
        let named = asked.flags.has("profile") ? "the profile's style" : "the style"
        asked.refused.append("\(named) \"\(choices.styleID)\" is not a style kmap can find — see `kmap styles`")
        return nil
    }

    /// `--split=` if given, else `--parts=`, else the profile's own mode.
    private static func splitMode(
        _ asked: inout BuildOptions,
        choices: BuildChoices,
        parts: Int?
    ) -> SplitMode? {
        if asked.flags.has("split") {
            guard let word = asked.word("split", among: BuildOptions.splitModes) else { return nil }
            return SplitMode(settingsID: word, count: parts ?? choices.parts)
        }
        if let parts { return .count(parts) }
        return SplitMode(settingsID: choices.splitMode, count: choices.parts)
    }

    /// `--format=` if given, else the profile's own; a profile from an older file writes
    /// card files.
    static func outputFormat(_ asked: inout BuildOptions, choices: BuildChoices) -> OutputFormat {
        asked.word("format", among: OutputFormat.allCases.map { ($0.rawValue, $0) })
            ?? OutputFormat(rawValue: choices.format) ?? .img
    }

    /// `--overlap` and `--land-overlap`, each stepped to the grid. Land may never exceed
    /// shape: refused rather than clamped, whichever of the two the profile supplied.
    private static func overlaps(
        _ asked: inout BuildOptions,
        choices: BuildChoices
    ) -> (shape: Int, land: Int) {
        let shapeAsked = asked.number("overlap", in: BuildOptions.overlap)
        let landAsked = asked.number("land-overlap", in: BuildOptions.overlap)
        for (name, value) in [("overlap", shapeAsked), ("land-overlap", landAsked)] {
            if let refusal = value.flatMap({ BuildChoices.offStep(name, $0) }) { asked.refused.append(refusal) }
        }
        let shape = BuildChoices.sane(shapeAsked ?? choices.shapeOverlap)
        // A land overlap nobody gave follows a lower shape one down, as for a profile.
        let land = landAsked.map(BuildChoices.sane) ?? min(BuildChoices.sane(choices.landOverlap), shape)
        if land > shape {
            asked.refused.append(
                "--land-overlap=\(land) is past --overlap=\(shape)"
                    + " — land would be painted onto ground the tile holds no cover for"
            )
        }
        return (shape, land)
    }
}
