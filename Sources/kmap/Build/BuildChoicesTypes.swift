import Foundation

/// The choice types a recipe is assembled from: how the output splits, which
/// language labels prefer, and which level ladder the map is drawn on.

/// How a finished map is cut into files. A receiver reads several files from one card and
/// draws them together, so tiles, their ids and the routing graph are the same either way;
/// the split decides only what can be installed or left off separately.
enum SplitMode: Equatable {
    /// As few files as the FAT32 file-size limit allows. Tiles are weighed after they are
    /// compiled rather than estimated.
    case fitCard
    /// One file per region in the map, so a region can be left off the card.
    case perRegion
    /// One file per country, gathering that country's regions together.
    case perCountry
    /// Exactly this many files, in equal weights.
    case count(Int)

    /// Stored in settings as a word plus a number, so a new case does not invalidate it.
    var settingsID: String {
        switch self {
        case .fitCard: return "fit"
        case .perRegion: return "region"
        case .perCountry: return "country"
        case .count: return "custom"
        }
    }

    var fileCount: Int {
        if case .count(let n) = self { return max(1, n) }
        return 0
    }

    init(settingsID: String, count: Int) {
        switch settingsID {
        case "region": self = .perRegion
        case "country": self = .perCountry
        case "custom": self = .count(max(1, count))
        default: self = .fitCard
        }
    }

    var label: String {
        switch self {
        case .fitCard: return t("automatic — as few as fit a card")
        case .perRegion: return t("one per region")
        case .perCountry: return t("one per country")
        case .count(let n): return tn("%d file(s)", n)
        }
    }
}

/// Which language the map's labels come out in. Becomes `--name-tag-list`; unrelated to
/// the language the interface speaks. Names and notes are held as catalogue keys rather
/// than text because these are `static let`s: a string built once would keep the language
/// it was first built in.
struct LabelLanguage: Equatable {
    let id: String
    let nameKey: String
    /// Passed to mkgmap's `--name-tag-list`; empty means the flag is not passed.
    let tagList: String
    let noteKey: String

    var name: String { t(nameKey) }
    var note: String { t(noteKey) }

    static let local = LabelLanguage(
        id: "local", nameKey: "Local",
        tagList: "",
        noteKey: "whatever the local mappers wrote — Russian in Russia, German in Germany")

    static let russian = LabelLanguage(
        id: "ru", nameKey: "Russian",
        tagList: "name:ru,int_name,name",
        noteKey: "prefer the Russian name where OSM has one")

    static let english = LabelLanguage(
        id: "en", nameKey: "English",
        tagList: "name:en,int_name,name",
        noteKey: "prefer the English name where OSM has one")

    static let all = [local, russian, english]
}

/// The zoom ladder: which map detail level is shown at which zoom. More levels means
/// smoother zooming and larger tiles.
struct LevelsProfile: Equatable {
    let id: String
    /// Catalogue keys rather than text; see `LabelLanguage`.
    let nameKey: String
    let levels: String
    let overviewLevels: String
    let noteKey: String

    var name: String { t(nameKey) }
    var note: String { t(noteKey) }

    /// mkgmap's default: four levels, smaller maps, visible jumps when zooming.
    static let standard = LevelsProfile(
        id: "standard",
        nameKey: "Standard (4 levels)",
        levels: "0:24, 1:22, 2:20, 3:18",
        overviewLevels: "4:17, 5:16, 6:15, 7:14, 8:13",
        noteKey: "mkgmap's default — smaller maps, coarser zoom steps")

    /// Seven tile levels, `0:24` down to `6:17`; mkgmap refuses a ninth ("Too many levels,
    /// the maximum is 8"). Rungs are spent at the coarse end so far zooms stay drawn: on a
    /// receiver, rung 24 is about 300 m, 23 about 600 m, 22 about 1.2 km, 21 about 3 km.
    static let smooth = LevelsProfile(
        id: "smooth",
        nameKey: "Smooth (8 levels)",
        levels: "0:24, 1:23, 2:22, 3:21, 4:19, 5:18, 6:17",
        // Level 16 belongs to the overview submap, not to the tiles: a receiver re-renders
        // per map holding data at the new level, so one submap replaces many tiles there.
        overviewLevels: "7:16, 8:15, 9:14, 10:13",
        noteKey: "smooth zoom close in; the overview never goes empty")

    static let all = [standard, smooth]

    var levelCount: Int { levels.split(separator: ",").count }

    /// DEM spacings for the coarse end of the ladder, one per zoom level, finest first.
    /// Valid only together with `--overview-dem-dist` in StageCompile: the coarsest entry
    /// sets the farthest zoom that still gets hillshading.
    private static let demBands = [26496, 52992, 106048]

    func demDists(oneArcSecond: Bool) -> String {
        // The fine end climbs geometrically from the source's own spacing to the first
        // named band, so the ladder stays monotonic whatever its length and source.
        let start = oneArcSecond ? 3312.0 : 9936.0
        let head = max(0, levelCount - LevelsProfile.demBands.count)
        let span = Double(LevelsProfile.demBands[0]) / start
        var out: [Int] = []
        for step in 0..<head {
            let value = start * pow(span, Double(step) / Double(head))
            // Held to multiples of 16, which is what mkgmap rounds them to anyway.
            out.append(Int((value / 16).rounded()) * 16)
        }
        return (out + LevelsProfile.demBands.suffix(levelCount - head))
            .map(String.init).joined(separator: ",")
    }
}

extension BuildRecipe {
    /// The day this build started, as it appears in every name it writes.
    var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: startedOn)
    }

    /// How much of a part's name survives into a file name. The rest of the basename is
    /// fixed, keeping the whole around fifty characters. Cut at a hyphen.
    static let fileNamePartLimit = 32

    /// How much of a profile's name a file name carries.
    private static let profileNamePartLimit = 16

    /// The name of one finished file: which profile built it, in what style, how much
    /// ground and when, with the date always last so builds sort apart on a card.
    ///
    /// - Parameters:
    ///   - ordinal: this file's place when one build comes out as several files.
    ///   - of: how many files the build produced; 1 carries no part marker.
    ///   - copy: which same-named build of the day this is; 2 and up go into the name,
    ///     so two builds that would collide on a card get "-2", "-3" instead. The name
    ///     does not carry the region — that is deliberate, it counts ground instead —
    ///     which is exactly how Monaco and Andorra in the same style on the same day
    ///     came out as one identical file name, and the second copied to a device
    ///     silently replaced the first.
    func fileName(ordinal: Int = 1, of total: Int = 1, copy: Int = 1) -> String {
        let part = total > 1 ? "p\(ordinal)-" : ""
        var parts = ["kmap"]
        if let profile = profileFileToken { parts.append(profile) }
        parts.append(styleFileToken)
        parts.append("\(regionsCovered)-regions")
        let bump = copy > 1 ? "-\(copy)" : ""
        return parts.joined(separator: "-") + "-\(part)\(dateStamp)\(bump).img"
    }

    /// The lowest copy number whose file names are all still free.
    ///
    /// Asked once per build, for every part at once: the parts of one build must share a
    /// number, or part one could come out "-2" while part two did not and the set would
    /// stop reading as a set.
    ///
    /// `taken` answers for the *other* builds in the output folder — the caller leaves
    /// its own destination out, so rebuilding the same map on the same day still replaces
    /// its own files rather than growing a number each time.
    func freeCopy(of total: Int, taken: (String) -> Bool) -> Int {
        var copy = 1
        // Bounded only against a `taken` that never says no; a folder of files runs out
        // of names to have taken long before this does.
        while copy < 10_000 {
            let anyTaken = (1...max(1, total)).contains { ordinal in
                taken(fileName(ordinal: ordinal, of: total, copy: copy))
            }
            if !anyTaken { return copy }
            copy += 1
        }
        return copy
    }

    /// The style as a file name says it, without the `typ:` prefix that marks a style
    /// carrying a TYP. The prefix namespaces the id and is not part of the style's name.
    private var styleFileToken: String {
        let bare = style.id.hasPrefix("typ:") ? String(style.id.dropFirst(4)) : style.id
        return FileTools.slugify(bare.replacingOccurrences(of: ":", with: "-"))
    }

    /// The profile as a file name says it, or nil where there is none. ASCII only, so a
    /// receiver or card reader can show it; a name with no ASCII leaves the slot out.
    private var profileFileToken: String? {
        let ascii = String(String.UnicodeScalarView(profileName.unicodeScalars.filter(\.isASCII)))
        let slug = String(FileTools.slugify(ascii).prefix(BuildRecipe.profileNamePartLimit))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    /// The lines shown under Map Info; mkgmap shows the first in BaseCamp only.
    /// Plain ASCII, no punctuation past a comma: Garmin's six-bit label alphabet drops a
    /// line from the first character it cannot hold. OSM attribution is licence-required.
    var copyrightLines: [String] {
        // kmap's own date rather than mkgmap's $LONGDATE$, which is written in the Java
        // locale and can contain characters the label alphabet does not hold.
        var lines = ["kmap \(Version.number), mkgmap $MKGMAP_VERSION$, built \(dateStamp)",
                     "(c) OpenStreetMap contributors, ODbL",
                     "Built by kmap \(Version.number), \(dateStamp)"]
        if contours || demLayer {
            lines.append("Elevation: \(demSources.replacingOccurrences(of: ",", with: " "))"
                         + (contours ? ", contours \(contourInterval) m" : ""))
        }
        // A borrowed look whose licence asks to be credited is credited here, where the
        // receiver shows it: the map is the product the licence speaks of.
        if let shipped = StyleCatalog.shippedPalette(id: style.id), !shipped.credit.isEmpty {
            lines.append(shipped.credit)
        }
        return lines
    }

    /// The dated folder each build writes into, so repeated builds of the same region do
    /// not overwrite each other.
    var outputFolderName: String {
        var parts: [String] = [dateStamp, slug]
        parts.append(FileTools.slugify(style.id.replacingOccurrences(of: ":", with: "-")))
        if contours { parts.append("\(contourInterval)m") }
        if demLayer { parts.append("dem") }
        return parts.joined(separator: "_")
    }

    /// The folder this build writes its finished maps into.
    var destinationDirectory: URL {
        outputDirectory.appendingPathComponent(outputFolderName, isDirectory: true)
    }

    /// Private scratch directory for this build, removed when it finishes.
    var workDirectory: URL {
        workRoot.appendingPathComponent(slug, isDirectory: true)
    }
}

extension BuildRecipe {
    /// The key a map is remembered by in the family-id registry: the region ids sorted and
    /// joined, so the same set always resolves to the same map.
    static func identityKey(_ regions: [Region]) -> String {
        regions.map(\.id).sorted().joined(separator: "+")
    }

    /// Geofabrik region ids whose OSM `name` is written in Cyrillic. Under code page 1252
    /// such names are silently transliterated to Latin.
    private static let cyrillicRegions: Set<String> = [
        "russia", "ukraine", "belarus", "bulgaria", "serbia", "macedonia",
        "montenegro", "kazakhstan", "kyrgyzstan", "mongolia", "tajikistan",
        "uzbekistan", "turkmenistan", "azerbaijan", "moldova", "abkhazia",
        "south-ossetia"
    ]

    /// The code page suggested for a region. Walks the region's parents, since a
    /// sub-region's own id says nothing about its alphabet while its parent's does.
    static func suggestedCodePage(for region: Region, in index: RegionIndex? = nil) -> Int {
        var cursor: Region? = region
        var hops = 0
        while let current = cursor, hops < 8 {
            if cyrillicRegions.contains(current.id.lowercased()) { return CodePage.cyrillic }
            guard let index, let parentID = current.parentID else { break }
            cursor = index.region(parentID)
            hops += 1
        }
        // Fall back to a substring check for callers without the index to hand.
        let id = region.id.lowercased()
        return cyrillicRegions.contains(where: { id.contains($0) })
            ? CodePage.cyrillic : CodePage.westernEuropean
    }
}

enum SplitAxis {
    case longitude, latitude

    /// Splits along whichever way the region is widest on the ground, so the halves are
    /// roughly equal in area rather than in degrees.
    static func best(for bbox: BBox) -> SplitAxis {
        guard bbox.isValid else { return .longitude }
        let midLat = (bbox.minLat + bbox.maxLat) / 2
        let lonKm = (bbox.maxLon - bbox.minLon) * 111.32 * cos(midLat * .pi / 180)
        let latKm = (bbox.maxLat - bbox.minLat) * 110.57
        return lonKm >= latKm ? .longitude : .latitude
    }
}
