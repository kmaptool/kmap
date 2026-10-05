import Foundation

/// Loads and saves `Settings`, tolerating a missing or malformed file.
final class SettingsStore: Sendable {
    private struct State {
        /// What the file holds, and what a save writes.
        var persisted: Settings
        /// Changes for this process only, applied over `persisted` in order; see
        /// `overrideForRun`.
        var overrides: [(inout Settings) -> Void] = []
        /// The stored settings with this run's overrides applied. Derived; never
        /// assigned directly.
        var settings: Settings
        /// Why the last save failed; nil once one succeeds.
        var saveFailure: Error?

        mutating func refresh() {
            var effective = persisted
            for override in overrides { override(&effective) }
            settings = effective
        }
    }

    /// The interface writes and a build reads, from tasks of its own, so every read and
    /// write goes through the lock.
    private let state: Locked<State>

    /// The stored settings with this run's overrides applied.
    var settings: Settings { state.withLock { $0.settings } }

    /// Why the last change could not be written, for a caller that did not keep the result.
    var saveFailure: Error? { state.withLock { $0.saveFailure } }

    init() {
        // An unreadable file is renamed rather than overwritten, since anything below
        // may save.
        if FileTools.exists(Paths.settingsFile), SettingsStore.load() == nil {
            let aside = Paths.settingsFile.deletingLastPathComponent()
                .appendingPathComponent("settings.unreadable.json")
            FileTools.removeIfPresent(aside)
            try? FileTools.move(Paths.settingsFile, to: aside)
        }
        let persisted = SettingsStore.load() ?? .default
        state = Locked(State(persisted: persisted, settings: persisted))
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
    ///
    /// Made to what the file holds now, under a lock: a TUI and a command line each save,
    /// and a change made to this run's older copy would undo the other's.
    @discardableResult
    func update(_ mutate: (inout Settings) -> Void) -> Result<Void, Error> {
        Paths.bootstrap()
        return FileLock.holding(Paths.settingsFile.appendingPathExtension("lock")) {
            let fresh = SettingsStore.load()
            state.withLock {
                if let fresh { $0.persisted = fresh }
                mutate(&$0.persisted)
                $0.refresh()
            }
            return save()
        }
    }

    /// Applies a change for this process only, as command-line flags do.
    ///
    /// Held as a layer over the stored settings, so a later durable change saves a copy
    /// that never contained the override.
    func overrideForRun(_ mutate: @escaping (inout Settings) -> Void) {
        state.withLock {
            $0.overrides.append(mutate)
            $0.refresh()
        }
    }

    /// Returns the family id for a map, allocated on first use and kept afterwards.
    ///
    /// - Parameter key: One region's id, or the joined ids of the regions built together.
    func familyID(for key: String) -> Int {
        if let known = settings.familyIDs[key] { return known }
        // Chosen inside the update, from the ids every run has given out so far.
        var chosen = 0
        update { settings in
            if let known = settings.familyIDs[key] {
                chosen = known
                return
            }
            let taken = Set(settings.familyIDs.values)
            // 6300..<7000, a band clear of Garmin's own product ids.
            var candidate = 6300
            while taken.contains(candidate), candidate < 7000 { candidate += 1 }
            settings.familyIDs[key] = candidate
            chosen = candidate
        }
        return chosen
    }

    /// Writes the file. The failure is the caller's to show: a read-only home or a full
    /// disk must not be reported as saved.
    @discardableResult
    func save() -> Result<Void, Error> {
        Paths.bootstrap()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state.withLock({ $0.persisted }))
            try FileTools.write(data, to: Paths.settingsFile)
            state.withLock { $0.saveFailure = nil }
            return .success(())
        } catch {
            state.withLock { $0.saveFailure = error }
            return .failure(error)
        }
    }
}
