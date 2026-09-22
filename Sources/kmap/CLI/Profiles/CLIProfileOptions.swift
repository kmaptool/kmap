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
        "zoom-plan", "descriptions", "theme", "hide", "split", "parts",
        "overlap", "land-overlap"
    ]
    private static let perRunOptions: Set<String> = [
        "profile", "out", "work", "keep-work", "heap", "connections", "memory",
        "max-nodes", "family-id", "repair-radius", "json", "verbose"
    ]

    /// Applies `flags` to `choices`, collecting every refusal so one run reports
    /// everything wrong with it. Nothing is applied where anything was refused.
    static func apply(_ flags: Flags, to choices: inout BuildChoices, store: SettingsStore) -> [String] {
        var asked = BuildOptions(flags)
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
        if let overlap = asked.number("overlap", in: BuildOptions.overlap) {
            choices.shapeOverlap = BuildChoices.sane(overlap)
            choices.landOverlap = min(choices.landOverlap, choices.shapeOverlap)
        }
        if let land = asked.number("land-overlap", in: BuildOptions.overlap) {
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
        if let theme = asked.word("theme", among: TypEdit.Theme.allCases.map(\.rawValue)) {
            choices.theme = theme
        }
        if flags.has("style") {
            let catalog = StyleCatalog(settings: store, toolchain: Toolchain(settings: store))
            if let style = asked.style(in: catalog) { choices.styleID = style.id }
        }
        if let sources = flags.value("sources") {
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
