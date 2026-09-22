import Foundation

/// Profiles described: the list `--profile` can name, one profile in full, and the same
/// as data for a reader that is not a person.
extension CLI {
    /// The name column of the list, capped so one long name does not push every summary
    /// off to the right.
    private static let profileNameColumnLimit = 30
    /// The label column of `kmap profiles show`.
    static let profileLabelColumn = 15

    /// What each profile holds, in ids rather than names since the ids are what `--style`,
    /// `--levels` and `--labels` take. The profile the interface opens on is marked; a
    /// build given no `--profile` takes none of them.
    static func listProfiles() -> Int32 {
        let store = SettingsStore()
        let profiles = store.profiles
        let current = store.currentProfile.id
        let width = min(profileNameColumnLimit, profiles.map(\.name.count).max() ?? 12)
        for profile in profiles {
            let name =
                profile.name.count >= width
                ? profile.name
                : profile.name.padding(toLength: width, withPad: " ", startingAt: 0)
            CLILog.line(profile.id == current ? "\(name)  (open in the interface)" : profile.name)
            CLILog.line("\(String(repeating: " ", count: width + 2))\(describe(profile.choices))")
        }
        CLILog.line("\n\(profiles.count) profile(s). Build with: kmap build … --profile=<name>")
        CLILog.line("Optional: a build given no --profile switches on only what its flags say.")
        CLIOutput.result([
            "profiles": .array(profiles.map { profileAsData($0, store: store) })
        ])
        return 0
    }

    /// One profile on one line.
    static func describe(_ choices: BuildChoices) -> String {
        var parts = ["style \(choices.styleID)"]
        parts.append(choices.contours ? "contours \(choices.contourInterval) m" : "no contours")
        parts.append(choices.demLayer ? "DEM" : "no DEM")
        if choices.contours || choices.demLayer { parts.append(choices.demSources) }
        parts.append("levels \(choices.levelsID)")
        parts.append("labels \(choices.labelLanguageID)")
        parts.append(choices.codePage == 0 ? "code page by region" : "code page \(choices.codePage)")
        parts.append("split \(choices.splitMode)" + (choices.splitMode == "custom" ? " \(choices.parts)" : ""))
        if !choices.hiddenFeatures.isEmpty {
            parts.append("hides \(choices.hiddenFeatures.joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }

    /// Every choice a profile holds, one row each, under the names the flags use.
    static func profileRows(_ profile: BuildProfile, store: SettingsStore) -> [(String, String)] {
        let c = profile.choices
        let current = profile.id == store.currentProfile.id
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        var rows: [(String, String)] = [
            ("name", profile.name + (current ? "  (open in the interface)" : "")),
            ("style", c.styleID),
            ("contours", c.contours ? "on · every \(c.contourInterval) m" : "off"),
            ("dem", onOff(c.demLayer)),
            ("summits", onOff(c.fixSummits)),
            ("sources", c.demSources),
            ("levels", c.levelsID),
            ("zoom-plan", zoomPlanName(c, store: store)),
            ("labels", c.labelLanguageID),
            ("code-page", c.codePage == 0 ? "auto — the region's own" : "\(c.codePage)"),
            ("route", onOff(c.routable)),
            ("repair-ends", onOff(c.healRoadEnds)),
            ("index", onOff(c.searchIndex)),
            ("word-index", onOff(c.splitNameIndex)),
            ("house-numbers", onOff(c.houseNumbers)),
            ("sea", onOff(c.generateSea)),
            ("descriptions", c.descriptions),
            ("custom-pois", onOff(c.customPOIs)),
            ("theme", c.theme),
            ("split", c.splitMode + (c.splitMode == "custom" ? " · \(c.parts) file(s)" : "")),
            ("overlap", "\(c.shapeOverlap) · land \(c.landOverlap)")
        ]
        if !c.hiddenFeatures.isEmpty {
            rows.append(("hide", c.hiddenFeatures.joined(separator: ",")))
        }
        return rows
    }

    static func profileAsData(_ profile: BuildProfile, store: SettingsStore) -> JSONValue {
        [
            "id": .string(profile.id), "name": .string(profile.name),
            "current": .bool(profile.id == store.currentProfile.id),
            "summary": .string(describe(profile.choices)),
            "choices": choicesAsData(profile.choices)
        ]
    }

    /// The choices as data, under the names the flags use.
    static func choicesAsData(_ choices: BuildChoices) -> JSONValue {
        [
            "style": .string(choices.styleID),
            "contours": .bool(choices.contours),
            "interval": .int(choices.contourInterval),
            "dem": .bool(choices.demLayer),
            "summits": .bool(choices.fixSummits),
            "sources": .string(choices.demSources),
            "levels": .string(choices.levelsID),
            "labels": .string(choices.labelLanguageID),
            "codePage": .int(choices.codePage),
            "split": .string(choices.splitMode),
            "parts": .int(choices.parts),
            "hide": .array(choices.hiddenFeatures.map(JSONValue.string))
        ]
    }

    private static func zoomPlanName(_ choices: BuildChoices, store: SettingsStore) -> String {
        if let plan = store.settings.zoomPlans.first(where: { $0.id == choices.zoomPlanID }) {
            return plan.name
        }
        return ZoomPlan.builtin(forLevels: choices.levelsID).name
    }
}
