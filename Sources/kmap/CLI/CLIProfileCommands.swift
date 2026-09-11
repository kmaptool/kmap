import Foundation

/// `kmap profiles`: the saved sets of build choices, managed from the shell with the
/// same vocabulary the build command speaks — every choice a profile holds has the same
/// flag on either command.
extension CLI {

    /// The verbs after `kmap profiles`; bare, it lists what there is.
    static func profiles(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first, !verb.hasPrefix("--") else {
            return listProfiles()
        }
        let rest = Array(arguments.dropFirst())
        let store = SettingsStore()
        switch verb {
        case "show":    return showProfile(rest, store: store)
        case "new":     return newProfile(rest, store: store)
        case "set":     return setProfile(rest, store: store)
        case "copy":    return copyProfile(rest, store: store)
        case "rename":  return renameProfile(rest, store: store)
        case "delete":  return deleteProfile(rest, store: store)
        case "use":     return useProfile(rest, store: store)
        default:
            return CLIOutput.failure(
                "unknown profiles verb \"\(verb)\" — one of: show, new, set, copy,"
                + " rename, delete, use; bare `kmap profiles` lists them", code: 2)
        }
    }

    // MARK: The verbs

    private static func showProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        let c = profile.choices
        let current = profile.id == store.currentProfile.id
        var rows: [(String, String)] = [
            ("name", profile.name + (current ? "  (open in the interface)" : "")),
            ("style", c.styleID),
            ("contours", c.contours ? "on · every \(c.contourInterval) m" : "off"),
            ("dem", c.demLayer ? "on" : "off"),
            ("summits", c.fixSummits ? "on" : "off"),
            ("sources", c.demSources),
            ("levels", c.levelsID),
            ("zoom-plan", zoomPlanName(c, store: store)),
            ("labels", c.labelLanguageID),
            ("code-page", c.codePage == 0 ? "auto — the region's own" : "\(c.codePage)"),
            ("route", c.routable ? "on" : "off"),
            ("repair-ends", c.healRoadEnds ? "on" : "off"),
            ("index", c.searchIndex ? "on" : "off"),
            ("word-index", c.splitNameIndex ? "on" : "off"),
            ("house-numbers", c.houseNumbers ? "on" : "off"),
            ("sea", c.generateSea ? "on" : "off"),
            ("descriptions", c.descriptions),
            ("custom-pois", c.customPOIs ? "on" : "off"),
            ("theme", c.theme),
            ("split", c.splitMode + (c.splitMode == "custom" ? " · \(c.parts) file(s)" : "")),
            ("overlap", "\(c.shapeOverlap) · land \(c.landOverlap)"),
        ]
        if !c.hiddenFeatures.isEmpty {
            rows.append(("hide", c.hiddenFeatures.joined(separator: ",")))
        }
        for (label, value) in rows {
            CLILog.line("\(label.padding(toLength: 15, withPad: " ", startingAt: 0))\(value)")
        }
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    private static func newProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            return CLIOutput.failure(
                "usage: kmap profiles new <name> [build options]", code: 2)
        }
        guard named(name, in: store) == nil else {
            return CLIOutput.failure(
                "a profile called \"\(name)\" already exists — `kmap profiles set` changes"
                + " it, `kmap profiles copy` starts another from it", code: 2)
        }
        var choices = BuildChoices()
        let refused = apply(Flags(Array(arguments.dropFirst())), to: &choices, store: store)
        guard refused.isEmpty else { return refuse(refused) }
        let made = store.addProfile(named: name, choices: choices)
        CLILog.line("\(made.name): \(describe(made.choices))")
        CLIOutput.result(["profile": profileAsData(made, store: store)])
        return 0
    }

    private static func setProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard var profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        let flags = Flags(Array(arguments.dropFirst()))
        guard !flags.names.isEmpty else {
            return CLIOutput.failure(
                "nothing to change — give `kmap profiles set` the same build options"
                + " `kmap build` takes, e.g. --interval=25 --no-dem", code: 2)
        }
        let refused = apply(flags, to: &profile.choices, store: store)
        guard refused.isEmpty else { return refuse(refused) }
        store.saveProfile(profile)
        CLILog.line("\(profile.name): \(describe(profile.choices))")
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    private static func copyProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard arguments.count >= 2 else {
            return CLIOutput.failure("usage: kmap profiles copy <name> <new-name>", code: 2)
        }
        guard let source = named(arguments[0], in: store) else {
            return missingProfile(arguments[0])
        }
        guard named(arguments[1], in: store) == nil else {
            return CLIOutput.failure("a profile called \"\(arguments[1])\" already exists",
                                     code: 2)
        }
        let made = store.addProfile(named: arguments[1], choices: source.choices)
        CLILog.line("\(source.name) → \(made.name)")
        CLIOutput.result(["profile": profileAsData(made, store: store)])
        return 0
    }

    private static func renameProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard arguments.count >= 2 else {
            return CLIOutput.failure("usage: kmap profiles rename <name> <new-name>", code: 2)
        }
        guard let profile = named(arguments[0], in: store) else {
            return missingProfile(arguments[0])
        }
        // A clash with itself is no clash: renaming Watch to watch is a case change.
        if let taken = named(arguments[1], in: store), taken.id != profile.id {
            return CLIOutput.failure("a profile called \"\(arguments[1])\" already exists",
                                     code: 2)
        }
        store.renameProfile(profile.id, to: arguments[1])
        let renamed = store.profile(profile.id) ?? profile
        CLILog.line("\(profile.name) → \(renamed.name)")
        CLIOutput.result(["profile": profileAsData(renamed, store: store)])
        return 0
    }

    private static func deleteProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        guard store.deleteProfile(profile.id) else {
            return CLIOutput.failure(
                "\"\(profile.name)\" is the last profile — the build form needs one, so"
                + " make another before deleting it", code: 2)
        }
        CLILog.line("deleted \(profile.name)")
        CLIOutput.result(["deleted": .string(profile.name)])
        return 0
    }

    private static func useProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        store.useProfile(profile.id)
        CLILog.line("\(profile.name) is what the interface opens on now")
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    // MARK: Shared pieces

    /// The profile a verb names, matched the way `--profile` matches: by name,
    /// case-insensitively.
    private static func named(_ name: String?, in store: SettingsStore) -> BuildProfile? {
        guard let name, !name.hasPrefix("--") else { return nil }
        return store.profiles.first {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private static func missingProfile(_ name: String?) -> Int32 {
        guard let name, !name.hasPrefix("--") else {
            return CLIOutput.failure("which profile? — `kmap profiles` lists them", code: 2)
        }
        return CLIOutput.failure(
            "no profile called \"\(name)\" — see `kmap profiles`", code: 2)
    }

    private static func refuse(_ lines: [String]) -> Int32 {
        for line in lines { CLILog.error(line) }
        if CLIOutput.isJSON {
            CLIOutput.result(["refused": .array(lines.map(JSONValue.string))])
        }
        return 2
    }

    private static func profileAsData(_ profile: BuildProfile,
                                      store: SettingsStore) -> JSONValue {
        ["id": .string(profile.id), "name": .string(profile.name),
         "current": .bool(profile.id == store.currentProfile.id),
         "summary": .string(describe(profile.choices)),
         "choices": choicesAsData(profile.choices)]
    }

    private static func zoomPlanName(_ choices: BuildChoices,
                                     store: SettingsStore) -> String {
        if let plan = store.settings.zoomPlans.first(where: { $0.id == choices.zoomPlanID }) {
            return plan.name
        }
        return ZoomPlan.builtin(forLevels: choices.levelsID).name
    }

    // MARK: Applying build options to a profile

    /// The build options a profile can hold. Everything else `kmap build` takes belongs
    /// to one run — the region, the output folder, memory — and is refused with a word
    /// to that effect.
    private static let profileOptions: Set<String> = [
        "contours", "no-contours", "dem", "no-dem", "summits", "no-summits",
        "route", "no-route",
        "repair-ends", "no-repair-ends", "index", "no-index",
        "word-index", "no-word-index", "lean-index",
        "house-numbers", "no-house-numbers", "sea", "no-sea",
        "custom-pois", "no-custom-pois",
        "style", "interval", "sources", "levels", "labels", "code-page",
        "zoom-plan", "descriptions", "theme", "hide", "split", "parts",
        "overlap", "land-overlap",
    ]
    private static let perRunOptions: Set<String> = [
        "profile", "out", "work", "keep-work", "heap", "connections", "memory",
        "max-nodes", "family-id", "repair-radius", "json", "verbose",
    ]

    /// Applies build options to a profile's choices, collecting every refusal so one run
    /// reports everything wrong with it. The vocabulary and the validation are the build
    /// command's own.
    private static func apply(_ flags: Flags, to choices: inout BuildChoices,
                              store: SettingsStore) -> [String] {
        var refused: [String] = []
        for name in flags.names.subtracting(profileOptions).sorted() {
            refused.append(perRunOptions.contains(name)
                ? "--\(name) belongs to one build, not to a profile"
                : "--\(name) is not a build option — see `kmap --help`")
        }

        func switched(_ name: String, _ current: Bool) -> Bool {
            if flags.has("no-" + name) { return false }
            if flags.has(name) { return true }
            return current
        }
        choices.contours = switched("contours", choices.contours)
        choices.demLayer = switched("dem", choices.demLayer)
        choices.fixSummits = switched("summits", choices.fixSummits)
        choices.routable = switched("route", choices.routable)
        choices.healRoadEnds = switched("repair-ends", choices.healRoadEnds)
        choices.searchIndex = switched("index", choices.searchIndex)
        choices.splitNameIndex = flags.has("lean-index")
            ? false : switched("word-index", choices.splitNameIndex)
        choices.houseNumbers = switched("house-numbers", choices.houseNumbers)
        choices.generateSea = switched("sea", choices.generateSea)
        choices.customPOIs = switched("custom-pois", choices.customPOIs)

        func number(_ name: String, in range: ClosedRange<Int>) -> Int? {
            guard let raw = flags.value(name) else { return nil }
            guard let value = Int(raw), range.contains(value) else {
                refused.append("--\(name)=\(raw) wants a number,"
                               + " \(range.lowerBound)-\(range.upperBound)")
                return nil
            }
            return value
        }
        if let interval = number("interval", in: 1...1000) {
            choices.contourInterval = interval
        }
        if let parts = number("parts", in: 1...64) { choices.parts = parts }
        if let overlap = number("overlap", in: 0...BuildChoices.overlapCeiling) {
            choices.shapeOverlap = BuildChoices.sane(overlap)
            choices.landOverlap = min(choices.landOverlap, choices.shapeOverlap)
        }
        if let land = number("land-overlap", in: 0...BuildChoices.overlapCeiling) {
            let saned = BuildChoices.sane(land)
            if saned > choices.shapeOverlap {
                refused.append("--land-overlap=\(saned) is past --overlap="
                               + "\(choices.shapeOverlap)")
            } else {
                choices.landOverlap = saned
            }
        }

        func word(_ name: String, among options: [String]) -> String? {
            guard let raw = flags.value(name) else { return nil }
            if let match = options.first(where: {
                $0.caseInsensitiveCompare(raw) == .orderedSame
            }) { return match }
            refused.append("--\(name)=\(raw) — one of " + options.joined(separator: ", "))
            return nil
        }
        if let levels = word("levels", among: LevelsProfile.all.map(\.id)) {
            choices.levelsID = levels
        }
        if let labels = word("labels", among: LabelLanguage.all.map(\.id)) {
            choices.labelLanguageID = labels
        }
        if let split = word("split", among: ["fit", "region", "country", "custom"]) {
            choices.splitMode = split
        }
        if let theme = word("theme", among: TypEdit.Theme.allCases.map(\.rawValue)) {
            choices.theme = theme
        }

        if let style = flags.value("style") {
            let catalog = StyleCatalog(settings: store,
                                       toolchain: Toolchain(settings: store))
            if catalog.availableStyles().contains(where: { $0.id == style }) {
                choices.styleID = style
            } else {
                refused.append("--style=\(style) is not a style kmap can find"
                               + " — see `kmap styles`")
            }
        }
        if let sources = flags.value("sources") {
            choices.demSources = CopernicusDEM.canonicalSourceList(sources)
        }
        if let raw = flags.value("code-page") {
            if raw.caseInsensitiveCompare("auto") == .orderedSame || raw == "0" {
                choices.codePage = 0
            } else if let value = Int(raw), value > 0 {
                choices.codePage = value
            } else {
                refused.append("--code-page=\(raw) — a number, or auto for the region's own")
            }
        }
        if flags.has("descriptions") {
            let raw = flags.value("descriptions") ?? "phone"
            let spelled = raw == "in-name" ? "inName" : raw
            if spelled == "off" || BuildRecipe.DescriptionCarrier(rawValue: spelled) != nil {
                choices.descriptions = spelled
            } else {
                refused.append("--descriptions=\(raw) — one of "
                    + (BuildRecipe.DescriptionCarrier.allCases.map(\.rawValue) + ["in-name"])
                        .joined(separator: ", "))
            }
        }
        if let asked = flags.value("hide") {
            let ids = asked.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let unknown = ids.filter { HideableFeature.feature(id: $0) == nil }
            if unknown.isEmpty {
                choices.hiddenFeatures = ids
            } else {
                refused.append("unknown --hide id(s): \(unknown.joined(separator: ", "))"
                               + " — see `kmap hideable`")
            }
        }
        if let wanted = flags.value("zoom-plan") {
            // A plan is matched by name, among the plans made for the (possibly just
            // changed) ladder, the built-in included.
            let plans = [ZoomPlan.builtin(forLevels: choices.levelsID)]
                + store.settings.zoomPlans.filter { $0.levelsID == choices.levelsID }
            if let plan = plans.first(where: {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }) {
                choices.zoomPlanID = plan.isBuiltin ? "" : plan.id
            } else {
                refused.append("--zoom-plan=\(wanted) — the plans for the"
                               + " \(choices.levelsID) ladder are: "
                               + plans.map(\.name).joined(separator: ", "))
            }
        }
        return refused
    }
}
