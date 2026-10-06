import Foundation

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

    /// Creates the first profile if the settings hold none. Decided again inside the update,
    /// on the file as it is now: 2 first runs at once would each write over the other's.
    func ensureProfile() {
        guard settings.profiles.isEmpty else { return }
        // `update` adds it, as it does whenever the file comes back without one.
        update { _ in }
    }

    /// The profile a settings file without any starts with.
    static func addFirstProfile(to settings: inout Settings) {
        var choices = BuildChoices()
        choices.styleID = settings.defaultStyleID
        let profile = BuildProfile(name: BuildProfile.firstName, choices: choices)
        settings.profiles = [profile]
        settings.lastProfileID = profile.id
    }

    /// Named against the profiles in the file as it is now, not this copy of it.
    @discardableResult
    func addProfile(named name: String, choices: BuildChoices = BuildChoices()) -> BuildProfile {
        var profile = BuildProfile(name: name, choices: choices)
        update {
            profile.name = Self.uniqueProfileName(name, among: $0.profiles)
            $0.profiles.append(profile)
        }
        return profile
    }

    /// Writes a profile back over the one with its id, or adds it if it has gone.
    @discardableResult
    func saveProfile(_ profile: BuildProfile) -> Result<Void, Error> {
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
        update {
            guard let at = $0.profiles.firstIndex(where: { $0.id == id }) else { return }
            $0.profiles[at].name = Self.uniqueProfileName(trimmed, among: $0.profiles, ignoring: id)
        }
    }

    /// Removes a profile. The last one is kept, since the build form requires one.
    @discardableResult
    func deleteProfile(_ id: String) -> Bool {
        guard settings.profiles.count > 1, settings.profiles.contains(where: { $0.id == id }) else { return false }
        // By id inside the update: it works on the file as it is now, not on this copy, and
        // says whether it was gone or the last one there.
        var deleted = false
        update {
            guard $0.profiles.count > 1, $0.profiles.contains(where: { $0.id == id }) else { return }
            $0.profiles.removeAll { $0.id == id }
            if $0.lastProfileID == id { $0.lastProfileID = $0.profiles.first?.id ?? "" }
            deleted = true
        }
        return deleted
    }

    /// The wanted name, or it followed by the first free number. Profiles are identified by
    /// id, so a duplicate name is valid; it is only unreadable in a list.
    func uniqueProfileName(_ wanted: String, ignoring id: String? = nil) -> String {
        Self.uniqueProfileName(wanted, among: settings.profiles, ignoring: id)
    }

    static func uniqueProfileName(
        _ wanted: String,
        among profiles: [BuildProfile],
        ignoring id: String? = nil
    ) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? BuildProfile.firstName : trimmed
        let taken = Set(
            profiles.filter { $0.id != id }
                .map { $0.name.lowercased() }
        )
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base.lowercased()) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
