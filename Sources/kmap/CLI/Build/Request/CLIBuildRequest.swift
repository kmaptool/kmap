import Foundation

extension CLI {
    /// What `kmap build` was asked for: every flag read against the profile, refused at once
    /// where wrong, and made into a recipe once the regions are known.
    struct BuildRequest {
        let options: BuildOptions
        let choices: BuildChoices
        let store: SettingsStore
        let style: MapStyle
        let split: SplitMode
        let format: OutputFormat
        let overlap: (shape: Int, land: Int)
        let drawn: RenderingChoices
        let hidden: [String]
        let contourInterval: Int
        let maxNodesPerTile: Int
        let familyID: Int?
        let heapGB: Int?
        let connections: Int?
        let repairRadius: Double?

        /// Nil where a flag was refused: the reasons are in `asked.refused`, all of them,
        /// so the command line is fixed in 1 go.
        init?(_ asked: inout BuildOptions, choices: BuildChoices, store: SettingsStore, catalog: StyleCatalog) {
            let settings = store.settings
            if let sources = asked.flags.value("sources") {
                let unknown = CLI.unknownSources(in: sources)
                if !unknown.isEmpty || CopernicusDEM.canonicalSourceList(sources).isEmpty {
                    asked.refused.append(
                        "--sources: "
                            + (unknown.isEmpty
                                ? "the list is empty" : "no source called \(unknown.joined(separator: ", "))")
                            + " — copernicus1, copernicus3, fabdem1, gedtm1, view1, view3, srtm1, srtm3 or alos1"
                    )
                }
            }
            heapGB = asked.number("heap", in: BuildOptions.heapGB)
            connections = asked.number("connections", in: BuildOptions.connections)
            if let memory = asked.number("memory", in: BuildOptions.memoryGB) { Machine.told(memory) }
            repairRadius = asked.repairRadius()
            let style = Self.chosenStyle(&asked, choices: choices, catalog: catalog)
            hidden = asked.hidden() ?? choices.hiddenFeatures
            drawn = RenderingChoices(&asked, choices: choices, settings: settings)
            let parts = asked.number("parts", in: BuildOptions.parts)
            contourInterval = asked.number("interval", in: BuildOptions.contourInterval) ?? choices.contourInterval
            maxNodesPerTile = asked.number("max-nodes", in: BuildOptions.nodesPerTile) ?? settings.maxNodesPerTile
            familyID = asked.number("family-id", in: BuildOptions.familyID)
            let split = Self.splitMode(&asked, choices: choices, parts: parts)
            format = Self.outputFormat(&asked, choices: choices)
            overlap = Self.overlaps(&asked, choices: choices)
            guard asked.refused.isEmpty, let style, let split else { return nil }
            self.style = style
            self.split = split
            options = asked
            self.choices = choices
            self.store = store
        }

        /// The recipe for the regions chosen: the flags where given, the profile elsewhere.
        func recipe(for chosen: [Region], in index: RegionIndex) -> BuildRecipe {
            let region = chosen[0]
            let settings = store.settings
            var recipe = BuildRecipe(
                region: region,
                extraRegions: Array(chosen.dropFirst()),
                style: style,
                contours: options.switched("contours", choices.contours),
                contourInterval: contourInterval,
                demLayer: options.switched("dem", choices.demLayer),
                fixSummits: options.switched("summits", choices.fixSummits),
                demSources: CopernicusDEM.canonicalSourceList(options.flags.value("sources") ?? choices.demSources),
                routable: options.switched("route", choices.routable),
                searchIndex: options.switched("index", choices.searchIndex),
                houseNumbers: options.switched("house-numbers", choices.houseNumbers),
                generateSea: options.switched("sea", choices.generateSea),
                // 0 leaves the code page to the region.
                codePage: drawn.codePage != 0 ? drawn.codePage : BuildRecipe.suggestedCodePage(for: region, in: index),
                levels: drawn.levels,
                nameTagList: drawn.labels.tagList,
                descriptions: drawn.descriptions,
                zoomPlan: drawn.zoomPlan,
                customPOIs: options.switched("custom-pois", choices.customPOIs),
                splitNameIndex: options.wordIndex(choices.splitNameIndex),
                healRoadEnds: options.switched("repair-ends", choices.healRoadEnds),
                hidden: Set(hidden),
                familyID: familyID ?? store.familyID(for: BuildRecipe.identityKey(chosen)),
                splitMode: split,
                countryOf: CLI.countries(of: chosen, in: index),
                outputDirectory: settings.outputURL,
                workRoot: settings.workURL,
                maxNodesPerTile: maxNodesPerTile,
                heapGB: heapGB ?? settings.resolvedHeapGB,
                downloadConnections: connections ?? settings.downloadConnections
            )
            recipe.healRadius = repairRadius ?? recipe.healRadius
            recipe.startedOn = Date()
            recipe.theme = drawn.theme
            recipe.format = format
            recipe.shapeOverlap = overlap.shape
            recipe.landOverlap = overlap.land
            return recipe
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
}
