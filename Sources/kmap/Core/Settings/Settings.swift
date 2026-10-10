import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms, where this module
// does not exist.
import FoundationNetworking
#endif

/// Persistent preferences: everything that is not re-answered per build.
struct Settings: Codable {
    var outputDirectory: String = Paths.defaultOutput.path
    /// Scratch space for downloads in progress, tiles and contours. Cleared once the
    /// maps are written, unless `keepWorkFiles` is set.
    var workDirectory: String = Paths.work.path
    var mkgmapJar: String = ""  // empty → auto-discover
    var javaBinary: String = ""  // empty → auto-discover
    var downloadConnections: Int = 4
    var javaHeapGB: Int = 0  // 0 → auto from physical memory
    /// OSM nodes per tile, and so how many tiles a map has.
    ///
    /// A tile's RGN section cannot exceed 16,777,215 bytes, which the format fixes and
    /// mkgmap enforces. mkgmap compiles one tile per core, so a lower value shortens a
    /// build at the cost of more tile boundaries.
    var maxNodesPerTile: Int = 1_200_000
    var keepWorkFiles: Bool = false

    /// How often a build asks whether the data packs have moved on. Monthly by default:
    /// the boundaries are 2.5 GB and are republished weekly, which is more traffic than a
    /// current map needs.
    var toolchainUpdates: ToolchainUpdates = .monthly
    /// When each pack was last asked about. Here rather than beside the file: this is
    /// when kmap asked, not what the server holds.
    var dataChecked: [String: Date] = [:]

    /// The interface language, empty until the first run has asked the system; see
    /// `L10n.bootstrap`. Map labels are decided by a profile's `labelLanguageID` and
    /// `codePage` instead.
    var uiLanguage: String = ""

    // MARK: Build choices
    //
    // Build-screen switches live in a profile, see `BuildChoices`, not here. A profile is
    // rewritten only from the profile screen.

    /// The profiles, unsorted; `SettingsStore.profiles` orders them.
    var profiles: [BuildProfile] = []
    /// The profile the build screen was last opened on.
    var lastProfileID: String = ""

    /// Custom zoom plans. The shipped ones are in `ZoomPlan.builtins` and cannot be lost
    /// by a write to this file.
    var zoomPlans: [ZoomPlan] = []

    /// The style a new profile starts with: the shipped openstreetmap.org look.
    var defaultStyleID: String = "osm-carto"

    /// The family id allocated to each map, so a rebuild keeps its id and no two maps
    /// share one. Tile numbers are `family × 10000 + n`, so maps sharing a family id
    /// hide each other on the receiver.
    var familyIDs: [String: Int] = [:]
    /// The reserved id a map had before it was given a new one, until a build has said
    /// so: the recipe screen allocates ids too, and may be left without building.
    var movedFamilyIDs: [String: Int] = [:]

    static let `default` = Settings()

    /// Heap to hand the JVM: `javaHeapGB` if set, else half of memory capped at 24 GB.
    var resolvedHeapGB: Int {
        if javaHeapGB > 0 { return javaHeapGB }
        // `Machine.memoryGB` honours `--memory`, which caps what a build may use.
        return max(2, min(24, Machine.memoryGB / 2))
    }

    var outputURL: URL { Paths.expand(outputDirectory) }
    var workURL: URL { workDirectory.isEmpty ? Paths.work : Paths.expand(workDirectory) }
}
