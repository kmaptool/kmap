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
    var mkgmapJar: String = ""          // empty → auto-discover
    var javaBinary: String = ""         // empty → auto-discover
    var downloadConnections: Int = 4
    var javaHeapGB: Int = 0             // 0 → auto from physical memory
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

    /// The style a new profile starts with. A fresh install carries rule sets only, see
    /// `StyleCatalog.builtinStyles`, so the default leaves drawing to the receiver.
    var defaultStyleID: String = "plain"

    /// The family id allocated to each map, so a rebuild keeps its id and no two maps
    /// share one. Tile numbers are `family × 10000 + n`, so maps sharing a family id
    /// hide each other on the receiver.
    var familyIDs: [String: Int] = [:]

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

/// Loads and saves `Settings`, tolerating a missing or malformed file.
final class SettingsStore {
    /// What the file holds, and what a save writes.
    private var persisted: Settings
    /// Changes for this process only, applied over `persisted` in order; see
    /// `overrideForRun`.
    private var overrides: [(inout Settings) -> Void] = []
    /// The stored settings with this run's overrides applied. Derived; never assigned
    /// directly.
    private(set) var settings: Settings

    init() {
        // An unreadable file is renamed rather than overwritten, since anything below
        // may save.
        if FileTools.exists(Paths.settingsFile), SettingsStore.load() == nil {
            let aside = Paths.settingsFile.deletingLastPathComponent()
                .appendingPathComponent("settings.unreadable.json")
            FileTools.removeIfPresent(aside)
            try? FileManager.default.moveItem(at: Paths.settingsFile, to: aside)
        }
        persisted = SettingsStore.load() ?? .default
        settings = persisted
        // The build form needs a profile; `ensureProfile` writes nothing once one exists.
        ensureProfile()
    }

    /// Reads the settings file, tolerating one written by an older build.
    ///
    /// Swift's synthesized decoder throws on a missing key even where the property has a
    /// default, so a file that fails to decode is merged onto the defaults rather than
    /// discarded.
    private static func load() -> Settings? {
        guard let data = try? Data(contentsOf: Paths.settingsFile) else { return nil }
        return decode(data)
    }

    /// Decodes settings from `data`, keeping every field that reads and dropping only
    /// those that do not, so one stale value costs its own field and no other.
    static func decode(_ data: Data) -> Settings? {
        if let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            return migrated(decoded)
        }
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(Settings.default),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData))
                as? [String: Any]
        else { return nil }

        func read(_ object: [String: Any]) -> Settings? {
            guard let bytes = try? JSONSerialization.data(withJSONObject: object) else {
                return nil
            }
            return try? JSONDecoder().decode(Settings.self, from: bytes)
        }

        // Each stored field is laid over the defaults only if the result still decodes.
        var merged = defaults
        for (key, value) in stored.sorted(by: { $0.key < $1.key }) {
            let was = merged[key]
            merged[key] = value
            if read(merged) == nil { merged[key] = was }
        }
        guard let decoded = read(merged) else { return nil }
        return migrated(decoded)
    }

    /// Replaces stored values that are superseded defaults rather than choices. The
    /// former node-per-tile default is not one of the values the settings screen offers.
    static func migrated(_ settings: Settings) -> Settings {
        var out = settings
        if out.maxNodesPerTile == 3_500_000 { out.maxNodesPerTile = Settings.default.maxNodesPerTile }
        return out
    }

    /// Applies a durable change: written to the file, and visible to this run unless an
    /// override covers the same field.
    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&persisted)
        refresh()
        save()
    }

    /// Applies a change for this process only, as command-line flags do.
    ///
    /// Held as a layer over the stored settings, so a later durable change saves a copy
    /// that never contained the override.
    func overrideForRun(_ mutate: @escaping (inout Settings) -> Void) {
        overrides.append(mutate)
        refresh()
    }

    private func refresh() {
        var effective = persisted
        for override in overrides { override(&effective) }
        settings = effective
    }

    /// Returns the family id for a map, allocated on first use and kept afterwards.
    ///
    /// - Parameter key: One region's id, or the joined ids of the regions built together.
    func familyID(for key: String) -> Int {
        if let known = settings.familyIDs[key] { return known }
        let taken = Set(settings.familyIDs.values)
        // 6300..<7000, a band clear of Garmin's own product ids.
        var candidate = 6300
        while taken.contains(candidate), candidate < 7000 { candidate += 1 }
        update { $0.familyIDs[key] = candidate }
        return candidate
    }

    func save() {
        Paths.bootstrap()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(persisted) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }
}
