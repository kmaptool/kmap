import Foundation

/// Everything the build form decides, gathered into one value, and the only place a build
/// choice is stored. Edits in the build form apply to the map being built, not the profile.
/// Excludes what belongs to one map or to Settings: the regions, the family id and the
/// output folder.
struct BuildChoices: Codable, Equatable {
    var styleID: String = "plain"
    var contours: Bool = true
    var contourInterval: Int = 10
    var demLayer: Bool = true
    var fixSummits: Bool = true
    var demSources: String = "view1,view3"
    var levelsID: String = LevelsProfile.smooth.id
    var labelLanguageID: String = LabelLanguage.local.id
    /// 0 leaves the choice open, so the region's own suggestion decides.
    var codePage: Int = 0
    var routable: Bool = true
    var healRoadEnds: Bool = false
    var searchIndex: Bool = true
    var splitNameIndex: Bool = true
    var houseNumbers: Bool = true
    var generateSea: Bool = true
    /// Which zoom plan, by id. Empty takes the built-in plan for the chosen ladder.
    var zoomPlanID: String = ""

    var descriptions: String = BuildRecipe.DescriptionCarrier.off.rawValue
    var customPOIs: Bool = false
    /// A set, held as a sorted list without duplicates, so plain equality compares two
    /// choices correctly. Kept canonical on every write by the observer below.
    var hiddenFeatures: [String] = [] {
        didSet { hiddenFeatures = BuildChoices.canonical(hiddenFeatures) }
    }

    static func canonical(_ features: [String]) -> [String] {
        Array(Set(features)).sorted()
    }
    var splitMode: String = "fit"
    var parts: Int = 1
    /// Which of the TYP's two drawings the build packs: both, day only, night only. A
    /// workaround for receivers that misdraw third-party maps after dark; a TYP with no
    /// night slots draws its day colours at any hour. See TypEdit.DayNight.
    var theme: String = TypEdit.Theme.all.rawValue
    /// How far past its own frame a tile may paint a shape, in map units, and the same for
    /// the land layer. The splitter and the compiler must be given the same shape figure,
    /// or a tile paints ground it holds no data for.
    var shapeOverlap: Int = Int(TileSplitter.shapeClipOverlap)
    var landOverlap: Int = Int(TileSplitter.landClipOverlap)

    /// Step and ceiling for an overlap. Coordinates round to their level's grid and the
    /// coarsest level land is drawn on rounds to 128 map units, so a finer step changes
    /// nothing. The ceiling is the tile grain the splitter reasons in.
    static let overlapStep = 128
    static let overlapCeiling = 2048

    static func sane(_ units: Int) -> Int {
        let stepped = (units + overlapStep / 2) / overlapStep * overlapStep
        return max(0, min(overlapCeiling, stepped))
    }
}

// In an extension so the memberwise initialiser, which every caller uses, is still
// synthesised.
extension BuildChoices {

    /// Decodes leniently, field by field: a missing or unreadable key takes the current
    /// default. The synthesised decoder would throw on the first missing key, and profiles
    /// live in one array, so a throw would lose every profile in the file.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BuildChoices()
        func read<T: Decodable>(_ key: CodingKeys, _ value: T) -> T {
            // Outer optional: the value would not decode as `T`. Inner: the key is absent.
            // Both take the default.
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? value
        }
        styleID = read(.styleID, fallback.styleID)
        contours = read(.contours, fallback.contours)
        contourInterval = read(.contourInterval, fallback.contourInterval)
        demLayer = read(.demLayer, fallback.demLayer)
        fixSummits = read(.fixSummits, fallback.fixSummits)
        demSources = read(.demSources, fallback.demSources)
        levelsID = read(.levelsID, fallback.levelsID)
        zoomPlanID = read(.zoomPlanID, fallback.zoomPlanID)
        labelLanguageID = read(.labelLanguageID, fallback.labelLanguageID)
        codePage = read(.codePage, fallback.codePage)
        routable = read(.routable, fallback.routable)
        healRoadEnds = read(.healRoadEnds, fallback.healRoadEnds)
        searchIndex = read(.searchIndex, fallback.searchIndex)
        splitNameIndex = read(.splitNameIndex, fallback.splitNameIndex)
        houseNumbers = read(.houseNumbers, fallback.houseNumbers)
        generateSea = read(.generateSea, fallback.generateSea)
        descriptions = read(.descriptions, fallback.descriptions)
        customPOIs = read(.customPOIs, fallback.customPOIs)
        // Observers do not run inside an initializer: canonical by hand here.
        hiddenFeatures = BuildChoices.canonical(read(.hiddenFeatures, fallback.hiddenFeatures))
        splitMode = read(.splitMode, fallback.splitMode)
        parts = read(.parts, fallback.parts)
        theme = read(.theme, fallback.theme)
        shapeOverlap = BuildChoices.sane(read(.shapeOverlap, fallback.shapeOverlap))
        landOverlap = min(BuildChoices.sane(read(.landOverlap, fallback.landOverlap)),
                          shapeOverlap)
    }
}

/// A named set of build choices, one per device or per kind of map. Chosen at the top of
/// the build form, which it fills in; a profile is rewritten only from the profile screen.
struct BuildProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var choices: BuildChoices

    init(id: String = UUID().uuidString, name: String, choices: BuildChoices = BuildChoices()) {
        self.id = id
        self.name = name
        self.choices = choices
    }

    /// The name the first profile carries on a fresh install. Not translated: it is stored
    /// data, and a stored name must not change with the interface language.
    fileprivate static let firstName = "Default"

    /// Orders profiles by name: Latin first, then Cyrillic, then everything else. The order
    /// is fixed by script rather than by locale, so it does not change with the interface
    /// language.
    static func precedes(_ a: BuildProfile, _ b: BuildProfile) -> Bool {
        let left = script(of: a.name), right = script(of: b.name)
        if left != right { return left < right }
        // Compared in the alphabet's own locale rather than the interface's, so the order
        // within a script is stable whatever language the screen is in.
        let locale = Locale(identifier: left == 1 ? "ru" : "en")
        let order = a.name.compare(b.name, options: [.caseInsensitive], range: nil,
                                   locale: locale)
        if order != .orderedSame { return order == .orderedAscending }
        return a.id < b.id
    }

    /// 0 Latin, 1 Cyrillic, 2 anything else — digits, punctuation, another script.
    private static func script(of name: String) -> Int {
        guard let first = name.trimmingCharacters(in: .whitespaces).unicodeScalars.first
        else { return 2 }
        switch first.value {
        case 0x0000...0x024F where first.properties.isAlphabetic: return 0
        case 0x0400...0x04FF: return 1
        default: return 2
        }
    }
}

// MARK: - The profiles a settings file holds

extension SettingsStore {

    /// Every profile, in the order they are offered everywhere: Latin names, then Cyrillic.
    var profiles: [BuildProfile] {
        settings.profiles.sorted(by: BuildProfile.precedes)
    }

    /// The profile the build form opens on: the one last chosen, or the first there is.
    /// Never nil; `ensureProfile` guarantees one exists.
    var currentProfile: BuildProfile {
        if let chosen = settings.profiles.first(where: { $0.id == settings.lastProfileID }) {
            return chosen
        }
        return profiles.first ?? BuildProfile(name: BuildProfile.firstName)
    }

    func profile(_ id: String) -> BuildProfile? {
        settings.profiles.first { $0.id == id }
    }

    /// Remembers which profile the build form was last opened on.
    func useProfile(_ id: String) {
        guard settings.lastProfileID != id else { return }
        update { $0.lastProfileID = id }
    }

    /// Creates the first profile if the settings hold none. Idempotent.
    func ensureProfile() {
        guard settings.profiles.isEmpty else { return }
        var choices = BuildChoices()
        choices.styleID = settings.defaultStyleID
        update {
            let profile = BuildProfile(name: BuildProfile.firstName, choices: choices)
            $0.profiles = [profile]
            $0.lastProfileID = profile.id
        }
    }

    @discardableResult
    func addProfile(named name: String, choices: BuildChoices = BuildChoices()) -> BuildProfile {
        let profile = BuildProfile(name: uniqueProfileName(name), choices: choices)
        update { $0.profiles.append(profile) }
        return profile
    }

    /// Writes a profile back over the one with its id, or adds it if it has gone.
    func saveProfile(_ profile: BuildProfile) {
        update {
            if let at = $0.profiles.firstIndex(where: { $0.id == profile.id }) {
                $0.profiles[at] = profile
            } else {
                $0.profiles.append(profile)
            }
        }
    }

    func renameProfile(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Settled before the write: `update` hands the settings out as `inout`, so reading
        // them again inside the closure violates exclusive access.
        let unique = uniqueProfileName(trimmed, ignoring: id)
        update {
            guard let at = $0.profiles.firstIndex(where: { $0.id == id }) else { return }
            $0.profiles[at].name = unique
        }
    }

    /// Removes a profile. The last one is kept, since the build form requires one.
    @discardableResult
    func deleteProfile(_ id: String) -> Bool {
        guard settings.profiles.count > 1,
              let at = settings.profiles.firstIndex(where: { $0.id == id }) else { return false }
        update {
            $0.profiles.remove(at: at)
            if $0.lastProfileID == id { $0.lastProfileID = $0.profiles.first?.id ?? "" }
        }
        return true
    }

    /// The wanted name, or it followed by the first free number. Profiles are identified by
    /// id, so a duplicate name is valid; it is only unreadable in a list.
    func uniqueProfileName(_ wanted: String, ignoring id: String? = nil) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? BuildProfile.firstName : trimmed
        let taken = Set(settings.profiles.filter { $0.id != id }
            .map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base.lowercased()) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - A profile meeting a recipe

extension BuildRecipe {

    /// The choices this recipe is carrying, lifted out of it.
    var choices: BuildChoices {
        BuildChoices(
            styleID: style.id,
            contours: contours,
            contourInterval: contourInterval,
            demLayer: demLayer,
            fixSummits: fixSummits,
            demSources: demSources,
            levelsID: levels.id,
            labelLanguageID: LabelLanguage.all
                .first { $0.tagList == nameTagList }?.id ?? LabelLanguage.local.id,
            codePage: codePage,
            routable: routable,
            healRoadEnds: healRoadEnds,
            searchIndex: searchIndex,
            splitNameIndex: splitNameIndex,
            houseNumbers: houseNumbers,
            generateSea: generateSea,
            zoomPlanID: zoomPlan.isBuiltin ? "" : zoomPlan.id,
            descriptions: descriptions.rawValue,
            customPOIs: customPOIs,
            hiddenFeatures: hidden.sorted(),
            splitMode: splitMode.settingsID,
            parts: splitMode.fileCount > 0 ? splitMode.fileCount : 1,
            theme: theme.rawValue,
            shapeOverlap: shapeOverlap,
            landOverlap: landOverlap)
    }

    /// Lays a set of choices over the recipe, leaving what belongs to this map alone: the
    /// regions, the family id, the output folder and the tile count.
    ///
    /// - Parameters:
    ///   - style: nil while the named style is still being searched for, in which case the
    ///     current style stays.
    ///   - regionCodePage: used when the profile leaves the code page open.
    ///   - plans: the zoom plans to resolve `zoomPlanID` against, passed in so the recipe
    ///     never reads settings itself.
    mutating func apply(_ choices: BuildChoices, style: MapStyle?, regionCodePage: Int,
                        plans: [ZoomPlan] = ZoomPlan.builtins) {
        if let style { self.style = style }
        contours = choices.contours
        contourInterval = choices.contourInterval
        demLayer = choices.demLayer
        fixSummits = choices.fixSummits
        demSources = CopernicusDEM.canonicalSourceList(choices.demSources)
        levels = LevelsProfile.all.first { $0.id == choices.levelsID } ?? .smooth
        // A deleted plan, or one made for another ladder, falls back to the built-in.
        zoomPlan = plans.first { $0.id == choices.zoomPlanID && $0.levelsID == levels.id }
            ?? ZoomPlan.builtin(forLevels: levels.id)
        nameTagList = LabelLanguage.all
            .first { $0.id == choices.labelLanguageID }?.tagList ?? ""
        codePage = choices.codePage != 0 ? choices.codePage : regionCodePage
        routable = choices.routable
        healRoadEnds = choices.healRoadEnds
        searchIndex = choices.searchIndex
        splitNameIndex = choices.splitNameIndex
        houseNumbers = choices.houseNumbers
        generateSea = choices.generateSea
        descriptions = BuildRecipe.DescriptionCarrier(rawValue: choices.descriptions) ?? .off
        customPOIs = choices.customPOIs
        hidden = Set(choices.hiddenFeatures)
        splitMode = SplitMode(settingsID: choices.splitMode, count: choices.parts)
        theme = TypEdit.Theme(rawValue: choices.theme) ?? .all
        shapeOverlap = BuildChoices.sane(choices.shapeOverlap)
        landOverlap = min(BuildChoices.sane(choices.landOverlap), shapeOverlap)
    }

    /// Whether the recipe still matches a profile. A code page of 0 counts as the region's
    /// own, and the style is compared by the id asked for, which differs from the id in use
    /// while a borrowed TYP is still being located.
    func matches(_ choices: BuildChoices, regionCodePage: Int, askedStyleID: String) -> Bool {
        var mine = self.choices
        mine.styleID = askedStyleID
        var theirs = choices
        if theirs.codePage == 0 { theirs.codePage = regionCodePage }
        theirs.demSources = CopernicusDEM.canonicalSourceList(theirs.demSources)
        return mine == theirs
    }
}
