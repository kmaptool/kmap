import Foundation

/// `kmap build`: the whole pipeline from one command line. Every flag the interactive form
/// offers has an equivalent here. The order is fixed: read the profile, let the flags
/// override it, refuse everything wrong at once, then hand a recipe to the pipeline.
extension CLI {
    static func build(_ arguments: [String]) async -> Int32 {
        guard let regionID = arguments.first(where: { !$0.hasPrefix("--") }) else {
            return CLIOutput.refuse("build needs a region id, e.g. austria")
        }
        let flags = Flags(arguments)

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
        if let found = catalog.availableStyles().first(where: { $0.id == choices.styleID }) { return found }
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

    /// `--overlap` and `--land-overlap`, each stepped to the grid. Land may never exceed
    /// shape: refused rather than clamped, whichever of the two the profile supplied.
    private static func overlaps(
        _ asked: inout BuildOptions,
        choices: BuildChoices
    ) -> (shape: Int, land: Int) {
        let shape = BuildChoices.sane(asked.number("overlap", in: BuildOptions.overlap) ?? choices.shapeOverlap)
        let land = BuildChoices.sane(asked.number("land-overlap", in: BuildOptions.overlap) ?? choices.landOverlap)
        if land > shape {
            asked.refused.append(
                "--land-overlap=\(land) is past --overlap=\(shape)"
                    + " — land would be painted onto ground the tile holds no cover for"
            )
        }
        return (shape, land)
    }
}
