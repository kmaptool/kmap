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
    var demSources: String = BuildRecipe.recommendedDEMSources
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
    /// What the map is written as; see `OutputFormat`.
    var format: String = OutputFormat.img.rawValue
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

    /// The refusal for an overlap given off the step, which `sane` would round silently.
    static func offStep(_ flag: String, _ units: Int) -> String? {
        units % overlapStep == 0 ? nil : "--\(flag)=\(units) is not a multiple of \(overlapStep)"
    }

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
        // A hand-edited 0 or a negative would stop or never end the tracer.
        let interval = read(.contourInterval, fallback.contourInterval)
        contourInterval = (1...1000).contains(interval) ? interval : fallback.contourInterval
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
        format = read(.format, fallback.format)
        theme = read(.theme, fallback.theme)
        shapeOverlap = BuildChoices.sane(read(.shapeOverlap, fallback.shapeOverlap))
        landOverlap = min(
            BuildChoices.sane(read(.landOverlap, fallback.landOverlap)),
            shapeOverlap
        )
    }
}
