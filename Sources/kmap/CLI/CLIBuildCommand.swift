import Foundation

/// `kmap build`: the whole pipeline from one command line.
///
/// Every flag the interactive form offers has an equivalent here. The order is fixed:
/// read the profile, let explicit flags override it, hand a recipe to the pipeline.
extension CLI {

    /// Reads the build flags one kind at a time, collecting every refusal, so one run
    /// reports everything wrong with it before any download.
    private struct BuildFlags {
        let flags: Flags
        /// Every unreadable flag lands here; the build is refused while it is not empty.
        var refused: [String] = []

        init(_ flags: Flags) { self.flags = flags }

        /// A switch the profile sets and either flag can move: `--no-dem` off, `--dem`
        /// on. Both spellings exist so a profile can be overridden in either direction.
        func switched(_ name: String, _ fromProfile: Bool) -> Bool {
            if flags.has("no-" + name) { return false }
            if flags.has(name) { return true }
            return fromProfile
        }

        /// A number a flag carries, or nil where the flag is absent. Out of range is
        /// refused rather than clamped.
        mutating func number(_ name: String, in range: ClosedRange<Int>) -> Int? {
            guard let raw = flags.value(name) else { return nil }
            guard let value = Int(raw) else {
                refused.append("--\(name)=\(raw) is not a number")
                return nil
            }
            guard range.contains(value) else {
                refused.append("--\(name)=\(value) is outside"
                               + " \(range.lowerBound)-\(range.upperBound)")
                return nil
            }
            return value
        }

        /// One of a known set of words, or nil where the flag is absent.
        mutating func word<T>(_ name: String, among options: [(id: String, value: T)]) -> T? {
            guard let raw = flags.value(name) else { return nil }
            if let match = options.first(where: {
                $0.id.caseInsensitiveCompare(raw) == .orderedSame
            }) { return match.value }
            refused.append("--\(name)=\(raw) — one of "
                           + options.map(\.id).joined(separator: ", "))
            return nil
        }

        /// `--repair-radius`: metres, within reason.
        mutating func repairRadius() -> Double? {
            guard let raw = flags.value("repair-radius") else { return nil }
            guard let value = Double(raw), value >= 0, value <= 50 else {
                refused.append("--repair-radius=\(raw) wants metres, 0 to 50")
                return nil
            }
            return value
        }

        /// `--code-page`: a number, or `auto` (and the 0 that stands for it), which
        /// hands the code page back to the region. Zero must not reach mkgmap.
        mutating func codePage() -> Int? {
            guard let raw = flags.value("code-page") else { return nil }
            if raw.caseInsensitiveCompare("auto") == .orderedSame || raw == "0" {
                return 0
            }
            if let value = Int(raw), value > 0 { return value }
            refused.append("--code-page=\(raw) — a number, or auto for the region's own")
            return nil
        }
    }

    /// A refusal on the way to a recipe, carrying the words the user is told.
    private struct Refusal: Error { let why: String }

    /// The style the build was asked for. An unknown style is refused rather than
    /// swapped for whichever comes first.
    private static func chosenStyle(_ flags: Flags, choices: BuildChoices,
                                    catalog: StyleCatalog) -> Result<MapStyle, Refusal> {
        let askedStyle = flags.value("style")
        let styleID = askedStyle ?? choices.styleID
        guard let style = catalog.availableStyles().first(where: { $0.id == styleID }) else {
            let named = askedStyle != nil
                ? "--style=\(styleID)"
                : flags.value("profile") != nil
                    ? "the profile's style \"\(styleID)\""
                    : "the style \"\(styleID)\""
            return .failure(Refusal(why: "\(named) is not a style kmap can find — see `kmap styles`"))
        }
        return .success(style)
    }

    /// What `--hide` asks to leave off the map. No --hide at all leaves the profile's
    /// own list standing; `--hide=` with nothing after it hides none. An unrecognised
    /// id is refused: nil, with the offenders already reported.
    private static func hiddenFeatures(_ flags: Flags, choices: BuildChoices) -> Set<String>? {
        guard let asked = flags.value("hide") else { return Set(choices.hiddenFeatures) }
        let askedToHide = asked
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let known = askedToHide.filter { HideableFeature.feature(id: $0) != nil }
        for unknown in askedToHide where HideableFeature.feature(id: unknown) == nil {
            CLILog.error("unknown --hide id \"\(unknown)\" — see `kmap hideable` for the list")
        }
        guard known.count == askedToHide.count else { return nil }
        return Set(known)
    }

    /// The regions of a build: several ids joined by "+" build one seamless map out of
    /// all of them. Each must exist and have an extract to download.
    private static func chosenRegions(_ regionID: String, in index: RegionIndex)
        -> Result<[Region], Refusal> {
        var chosen: [Region] = []
        for id in regionID.split(separator: "+").map(String.init) {
            guard let found = index.region(id) else {
                return .failure(Refusal(why: "no region with id \"\(id)\" — try `kmap regions \(id)`"))
            }
            guard found.pbfURL != nil else {
                return .failure(Refusal(why: "\(found.name) has no downloadable extract"
                                        + " — pick a sub-region"))
            }
            chosen.append(found)
        }
        return .success(chosen)
    }

    /// How the map is drawn and labelled: the level ladder, zoom plan, theme, label
    /// language, description carrier and code page — each from its flag, else from the
    /// profile, else the default.
    private struct RenderingChoices {
        let levels: LevelsProfile
        let zoomPlan: ZoomPlan
        let theme: TypEdit.Theme
        let labels: LabelLanguage
        let descriptions: BuildRecipe.DescriptionCarrier
        let codePage: Int
    }

    private static func resolveRendering(_ asked: inout BuildFlags, choices: BuildChoices,
                                         settings: Settings) -> RenderingChoices {
        let flags = asked.flags
        let levels = asked.word("levels", among: LevelsProfile.all.map { ($0.id, $0) })
            ?? LevelsProfile.all.first { $0.id == choices.levelsID } ?? .smooth

        // A plan is matched by name rather than by id, which is a UUID for custom plans.
        // Only plans made for this level ladder are offered.
        let forLadder = settings.zoomPlans.filter { $0.levelsID == levels.id }
        let zoomPlan = asked.word("zoom-plan", among: forLadder.map { ($0.name.lowercased(), $0) })
            ?? forLadder.first { $0.id == choices.zoomPlanID }
            ?? ZoomPlan.builtin(forLevels: levels.id)
        let fromProfile = TypEdit.Theme(rawValue: choices.theme) ?? .all
        let theme = asked.word("theme", among: TypEdit.Theme.allCases.map { ($0.rawValue, $0) })
            ?? fromProfile
        let labels = asked.word("labels", among: LabelLanguage.all.map { ($0.id, $0) })
            ?? LabelLanguage.all.first { $0.id == choices.labelLanguageID } ?? .local

        // The kebab-case spelling used by the help text is accepted beside the raw value.
        let carriers = BuildRecipe.DescriptionCarrier.allCases.map { ($0.rawValue, $0) }
            + [(id: "in-name", value: BuildRecipe.DescriptionCarrier.inName)]
        let descriptions: BuildRecipe.DescriptionCarrier =
            asked.word("descriptions", among: carriers)
            ?? (flags.has("descriptions")
                ? .phone
                : BuildRecipe.DescriptionCarrier(rawValue: choices.descriptions) ?? .off)

        return RenderingChoices(levels: levels, zoomPlan: zoomPlan, theme: theme,
                                labels: labels, descriptions: descriptions,
                                codePage: asked.codePage() ?? choices.codePage)
    }

    static func build(_ arguments: [String]) async -> Int32 {
        guard let regionID = arguments.first(where: { !$0.hasPrefix("--") }) else {
            return CLIOutput.failure("build needs a region id, e.g. austria", code: 2)
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

        // Nothing is switched on that was not asked for, unless --profile names a set to
        // start from; a flag overrides either.
        guard let choices = chosenChoices(flags.value("profile"), in: store) else {
            let wanted = flags.value("profile") ?? ""
            return CLIOutput.failure("no profile called \"\(wanted)\" — see `kmap profiles`",
                                     code: 2)
        }

        // Stored settings a build may overrule for one run. Out of range is refused
        // rather than clamped.
        var asked = BuildFlags(flags)
        func switched(_ name: String, _ fromProfile: Bool) -> Bool {
            asked.switched(name, fromProfile)
        }
        func number(_ name: String, in range: ClosedRange<Int>) -> Int? {
            asked.number(name, in: range)
        }
        func word<T>(_ name: String, among options: [(id: String, value: T)]) -> T? {
            asked.word(name, among: options)
        }
        let askedHeap = number("heap", in: 1...512)
        let askedConnections = number("connections", in: 1...Downloader.maxParts)
        if let memory = number("memory", in: 1...4096) { Machine.told(memory) }
        let askedRepairRadius = asked.repairRadius()

        let style: MapStyle
        switch chosenStyle(flags, choices: choices, catalog: catalog) {
        case .success(let found): style = found
        case .failure(let refusal): return CLIOutput.failure(refusal.why, code: 2)
        }

        guard let hideIDs = hiddenFeatures(flags, choices: choices) else { return 2 }

        let drawn = resolveRendering(&asked, choices: choices, settings: settings)
        let wantedCodePage = drawn.codePage

        let parts = number("parts", in: 1...64)
        let interval = number("interval", in: 1...1000) ?? choices.contourInterval
        let maxNodes = number("max-nodes", in: 100_000...20_000_000) ?? settings.maxNodesPerTile
        let askedFamilyID = number("family-id", in: 1...65535)
        let split = splitMode(from: flags, choices: choices, parts: parts)
        if split == nil {
            asked.refused.append("--split=\(flags.value("split") ?? "")"
                                 + " — one of fit, region, country, custom")
        }

        // Read here rather than at the point of use: every refusal has to be collected
        // before the guard below.
        let wantedOverlap = BuildChoices.sane(
            number("overlap", in: 0...BuildChoices.overlapCeiling) ?? choices.shapeOverlap)
        let wantedLand = BuildChoices.sane(
            number("land-overlap", in: 0...BuildChoices.overlapCeiling) ?? choices.landOverlap)
        // Land overlap may never exceed shape overlap; refused rather than clamped.
        if wantedLand > wantedOverlap {
            asked.refused.append("--land-overlap=\(wantedLand) is past --overlap=\(wantedOverlap)"
                                 + " — land would be painted onto ground the tile holds no"
                                 + " cover for")
        }

        guard asked.refused.isEmpty else {
            for line in asked.refused { CLILog.error(line) }
            if CLIOutput.isJSON {
                CLIOutput.result(["refused": .array(asked.refused.map(JSONValue.string))])
            }
            return 2
        }

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
        case .failure(let refusal): return CLIOutput.failure(refusal.why, code: 2)
        }
        let region = chosen[0]

        var recipe = BuildRecipe(
            region: region,
            extraRegions: Array(chosen.dropFirst()),
            style: style,
            contours: switched("contours", choices.contours),
            contourInterval: interval,
            demLayer: switched("dem", choices.demLayer),
            fixSummits: switched("summits", choices.fixSummits),
            demSources: CopernicusDEM.canonicalSourceList(flags.value("sources")
                ?? choices.demSources),
            routable: switched("route", choices.routable),
            searchIndex: switched("index", choices.searchIndex),
            houseNumbers: switched("house-numbers", choices.houseNumbers),
            generateSea: switched("sea", choices.generateSea),
            // 0 means the profile leaves the code page to the region.
            codePage: wantedCodePage != 0
                ? wantedCodePage
                : BuildRecipe.suggestedCodePage(for: region, in: index),
            levels: drawn.levels,
            nameTagList: drawn.labels.tagList,
            descriptions: drawn.descriptions,
            zoomPlan: drawn.zoomPlan,
            customPOIs: switched("custom-pois", choices.customPOIs),
            // `--lean-index` is the retired spelling of --no-word-index, still accepted.
            splitNameIndex: flags.has("lean-index")
                ? false
                : switched("word-index", choices.splitNameIndex),
            healRoadEnds: switched("repair-ends", choices.healRoadEnds),
            hidden: hideIDs,
            familyID: askedFamilyID ?? store.familyID(for: BuildRecipe.identityKey(chosen)),
            splitMode: split ?? .fitCard,
            countryOf: countries(of: chosen, in: index),
            outputDirectory: store.settings.outputURL,
            workRoot: store.settings.workURL,
            // Smaller tiles mean more of them, and mkgmap compiles one per core.
            maxNodesPerTile: maxNodes,
            heapGB: askedHeap ?? settings.resolvedHeapGB,
            downloadConnections: askedConnections ?? settings.downloadConnections)
        recipe.healRadius = askedRepairRadius ?? recipe.healRadius
        recipe.startedOn = Date()
        // The compiler and the splitter are handed the same overlap figures; see
        // StageSplit.
        recipe.theme = drawn.theme
        recipe.shapeOverlap = wantedOverlap
        recipe.landOverlap = wantedLand

        // Said before any work starts, and naming the one command that fixes it: a build
        // that fails ten minutes in because there is no Java helps nobody.
        guard toolchain.canBuild else {
            let missing = Toolchain.missingRequirements(in: toolchain.status()).map(\.id)
            return CLIOutput.failure(
                "\(missing.joined(separator: " and ")) missing — run: kmap install", code: 2)
        }

        let pipeline = BuildPipeline(recipe: recipe, settings: store,
                                     toolchain: toolchain, styles: catalog,
                                     showing: CLIOutput.showing)
        pipeline.start()
        return await follow(pipeline, landingIn: recipe.destinationDirectory)
    }

    /// Decides which polls of a running stage earn a progress event: its bar moved, the
    /// whole build's bar moved, or the stage said something new about what it is doing.
    /// The last matters for work with no percentage — verifying a cached extract,
    /// splitting into tiles — where the detail line is the only sign of life.
    struct ProgressGate {
        private var lastOverall = -1.0
        private var lastFraction: [String: Double] = [:]
        private var lastDetail: [String: String] = [:]

        mutating func speaks(stage id: String, fraction: Double?, overall: Double,
                             detail: String) -> Bool {
            let moved = abs((fraction ?? 0) - (lastFraction[id] ?? -1)) >= 0.01
            let grew = abs(overall - lastOverall) >= 0.01
            let said = detail != lastDetail[id]
            guard moved || grew || said else { return false }
            lastFraction[id] = fraction ?? 0
            lastDetail[id] = detail
            lastOverall = overall
            return true
        }
    }

    /// Streams the log as it arrives, reports each stage transition once, and answers
    /// with the exit code the run earned.
    ///
    /// The same loop feeds both shapes of output: the prose a person reads, and the event
    /// stream a program reads. Progress is reported when it has visibly moved, so a long
    /// build does not fill the stream with lines saying the same thing.
    static func follow(_ pipeline: BuildPipeline, landingIn destination: URL) async -> Int32 {
        var printed = 0
        var lastStage: [String: BuildPipeline.StageStatus] = [:]
        var gate = ProgressGate()
        while true {
            let lines = pipeline.log.snapshot()
            if lines.count > printed {
                for line in lines[printed...] {
                    CLILog.line(prefix(line) + line.text)
                    CLIOutput.log(line)
                }
                printed = lines.count
            }

            let snapshot = pipeline.snapshot()
            for stage in snapshot.stages where lastStage[stage.id.rawValue] != stage.status {
                lastStage[stage.id.rawValue] = stage.status
                if stage.status == .running { CLILog.line("── \(stage.id.title)") }
                CLIOutput.stage(stage.id.rawValue, stage.status.rawValue,
                                title: stage.id.title, detail: stage.detail)
            }

            if CLIOutput.isJSON {
                let overall = snapshot.overall
                for stage in snapshot.stages where stage.status == .running {
                    guard gate.speaks(stage: stage.id.rawValue, fraction: stage.fraction,
                                      overall: overall, detail: stage.detail) else { continue }
                    CLIOutput.progress(stage: stage.id.rawValue, fraction: stage.fraction,
                                       overall: overall, detail: stage.detail)
                }
            }

            if snapshot.finished {
                if let failure = snapshot.failure {
                    return CLIOutput.failure("\nfailed: \(failure)")
                }
                if snapshot.cancelled {
                    CLILog.line("\ncancelled")
                    CLIOutput.result(["cancelled": .bool(true)])
                    return 130
                }
                CLILog.line("")
                for output in snapshot.outputs {
                    CLILog.line("\(output.name)  \(Fmt.bytes(output.size))")
                }
                CLILog.line(Paths.display(destination))
                // The stream's progress always closes at 1, so a parser can drive its
                // bar to the end without special-casing the result event.
                CLIOutput.progress(stage: nil, fraction: nil, overall: snapshot.overall)
                CLIOutput.result([
                    "destination": .string(destination.path),
                    "outputs": .array(snapshot.outputs.map {
                        ["name": .string($0.name), "path": .string($0.url.path),
                         "bytes": .int(Int($0.size))]
                    }),
                    "stages": .array(snapshot.stages.map { stage in
                        ["id": .string(stage.id.rawValue),
                         "title": .string(stage.id.title),
                         "status": .string(stage.status.rawValue),
                         "seconds": .double(stage.seconds),
                         "peakBytes": .int(Int(stage.peakBytes))]
                    }),
                    "seconds": .double((snapshot.finishedAt ?? Date())
                        .timeIntervalSince(snapshot.startedAt)),
                ])
                return 0
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// The mark in front of a line: what kind of thing it is first, how much it matters
    /// where the kind says nothing.
    ///
    /// These are printed straight out, not drawn on a `Surface`, so the substitution a
    /// Windows console needs is made here.
    static func prefix(_ event: LogEvent) -> String {
        switch event.kind {
        case .step: return "> "
        case .ok: return "\(Glyph.drawable("✓")) "
        case .plain, .output:
            switch event.severity {
            case .warn: return "! "
            case .error: return "\(Glyph.drawable("✕")) "
            case .debug, .info: return "  "
            }
        }
    }
}
