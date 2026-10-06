import Foundation

/// Build options applied to a profile's choices. The vocabulary and the validation are
/// the build command's own; what belongs to one run rather than to a profile is refused
/// with a word to that effect.
extension CLI {
    private static let profileOptions: Set<String> = [
        "contours", "no-contours", "dem", "no-dem", "summits", "no-summits",
        "route", "no-route", "repair-ends", "no-repair-ends", "index", "no-index",
        "word-index", "no-word-index", "lean-index",
        "house-numbers", "no-house-numbers", "sea", "no-sea",
        "custom-pois", "no-custom-pois",
        "style", "interval", "sources", "levels", "labels", "code-page",
        "zoom-plan", "descriptions", "theme", "hide", "split", "parts", "format",
        "overlap", "land-overlap"
    ]
    private static let perRunOptions: Set<String> = [
        "profile", "out", "work", "keep-work", "heap", "connections", "memory",
        "max-nodes", "family-id", "repair-radius", "json", "verbose"
    ]

    /// The build options that stand alone or take a value, and so take it only after `=`.
    static let valuedOnlyAfterEquals: Set<String> = ["descriptions"]

    /// The build options that hold a value, so `--key value` reads as `--key=value` does.
    static let buildValuedOptions: Set<String> =
        profileOptions.union(perRunOptions)
        .subtracting(BuildOptions.switches).subtracting(valuedOnlyAfterEquals).subtracting(["json", "verbose"])

    /// Every flag `kmap build` reads; anything else on its line is a mistake, not a no-op.
    static func unknownBuildOptions(in flags: Flags) -> [String] {
        flags.names.subtracting(profileOptions).subtracting(perRunOptions).sorted()
    }

    /// The elevation source ids a list may name: the direct sources, the 2 Viewfinder
    /// resolutions, and pyhgtmap's own behind a login. Returns the rest.
    static func unknownSources(in csv: String) -> [String] {
        let known = Set(
            DEMSources.all.map(\.sourceID) + ["view1", "view3"]
                + ElevationLogins.Service.allCases.flatMap(\.sourceIDs)
        )
        return csv.split(separator: ",").map {
            CopernicusDEM.canonicalSourceID($0.trimmingCharacters(in: .whitespaces))
        }
        .filter { !$0.isEmpty && !known.contains($0) }
    }

    /// Applies `flags` to `choices`, collecting every refusal so one run reports
    /// everything wrong with it. Nothing is applied where anything was refused.
    static func apply(_ flags: Flags, to choices: inout BuildChoices, store: SettingsStore) -> [String] {
        var asked = BuildOptions(flags)
        for extra in flags.positionals { asked.refused.append("\"\(extra)\" is not a build option") }
        for name in flags.names.subtracting(profileOptions).sorted() {
            asked.refused.append(
                perRunOptions.contains(name)
                    ? "--\(name) belongs to one build, not to a profile"
                    : "--\(name) is not a build option — see `kmap --help`"
            )
        }

        choices.contours = asked.switched("contours", choices.contours)
        choices.demLayer = asked.switched("dem", choices.demLayer)
        choices.fixSummits = asked.switched("summits", choices.fixSummits)
        choices.routable = asked.switched("route", choices.routable)
        choices.healRoadEnds = asked.switched("repair-ends", choices.healRoadEnds)
        choices.searchIndex = asked.switched("index", choices.searchIndex)
        choices.splitNameIndex = asked.wordIndex(choices.splitNameIndex)
        choices.houseNumbers = asked.switched("house-numbers", choices.houseNumbers)
        choices.generateSea = asked.switched("sea", choices.generateSea)
        choices.customPOIs = asked.switched("custom-pois", choices.customPOIs)

        if let interval = asked.number("interval", in: BuildOptions.contourInterval) {
            choices.contourInterval = interval
        }
        if let parts = asked.number("parts", in: BuildOptions.parts) { choices.parts = parts }
        // A lower shape overlap pulls the land overlap down with it; a land overlap past
        // the shape one is refused.
        let shapeAsked = asked.number("overlap", in: BuildOptions.overlap)
        let landAsked = asked.number("land-overlap", in: BuildOptions.overlap)
        // Steps of 128 only: another figure would be rounded to one, silently.
        for (name, value) in [("overlap", shapeAsked), ("land-overlap", landAsked)] {
            if let refusal = value.flatMap({ BuildChoices.offStep(name, $0) }) { asked.refused.append(refusal) }
        }
        if let overlap = shapeAsked {
            choices.shapeOverlap = BuildChoices.sane(overlap)
            choices.landOverlap = min(choices.landOverlap, choices.shapeOverlap)
        }
        if let land = landAsked {
            let stepped = BuildChoices.sane(land)
            if stepped > choices.shapeOverlap {
                asked.refused.append("--land-overlap=\(stepped) is past --overlap=\(choices.shapeOverlap)")
            } else {
                choices.landOverlap = stepped
            }
        }

        if let levels = asked.word("levels", among: LevelsProfile.all.map(\.id)) {
            choices.levelsID = levels
        }
        if let labels = asked.word("labels", among: LabelLanguage.all.map(\.id)) {
            choices.labelLanguageID = labels
        }
        if let split = asked.word("split", among: BuildOptions.splitModes) {
            choices.splitMode = split
        }
        if let format = asked.word("format", among: BuildOptions.outputFormats) {
            choices.format = format
        }
        if let theme = asked.word("theme", among: TypEdit.Theme.allCases.map(\.rawValue)) {
            choices.theme = theme
        }
        if flags.has("style") {
            let catalog = StyleCatalog(settings: store, toolchain: Toolchain(settings: store))
            if let style = asked.style(in: catalog) { choices.styleID = style.id }
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
            choices.demSources = CopernicusDEM.canonicalSourceList(sources)
        }
        if let codePage = asked.codePage() { choices.codePage = codePage }
        if let carrier = asked.descriptions() { choices.descriptions = carrier.rawValue }
        if let hidden = asked.hidden() { choices.hiddenFeatures = hidden }
        // Matched among the plans for the ladder as it now stands, the built-in included.
        if let plan = asked.zoomPlan(forLadder: choices.levelsID, in: store.settings) {
            choices.zoomPlanID = plan.isBuiltin ? "" : plan.id
        }
        return asked.refused
    }
}
