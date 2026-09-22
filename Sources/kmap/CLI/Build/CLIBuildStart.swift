import Foundation

/// What a command-line build starts from before any flag is read.
extension CLI {
    /// `bare`, or the choices of the profile named by `--profile`, matched on name rather
    /// than id. The profile is only read.
    ///
    /// - Returns: nil when a name was given and no profile answers to it.
    static func chosenChoices(_ wanted: String?, in store: SettingsStore) -> BuildChoices? {
        guard let wanted else { return bare }
        return store.profiles.first {
            $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
        }?.choices
    }

    /// What a bare command line means: every switch off, so no TYP, contours, DEM, routing
    /// or index unless a flag or `--profile` turns it on. The non-switch settings keep
    /// their defaults, having no off state.
    static let bare: BuildChoices = {
        var choices = BuildChoices()
        choices.styleID = "plain"
        choices.contours = false
        choices.demLayer = false
        choices.fixSummits = false
        choices.routable = false
        choices.searchIndex = false
        choices.splitNameIndex = false
        choices.houseNumbers = false
        choices.generateSea = false
        return choices
    }()
}
