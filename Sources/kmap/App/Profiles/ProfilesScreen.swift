import Foundation

/// Named sets of build choices. A profile fills the build form in; it is rewritten only
/// from here. `/` opens search, leaving letters as keys.
final class ProfilesScreen: Screen {
    var page: Page { Page(t("profiles"), subject: search.subject, keys: keys) }

    private var keys: [Hint] {
        if search.open { return search.hints }
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if naming != nil {
            return [Hint(key: Glyph.enter, label: t("accept")), Hint(key: "esc", label: t("cancel"))]
        }
        return [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("open")),
            Hint(key: "n", label: t("new")),
            Hint(key: "c", label: t("copy")),
            Hint(key: "r", label: t("rename")),
            Hint(key: "d", label: t("delete")),
            Hint(key: "m", label: t("make current")),
            Hint(key: "/", label: t("search")),
            Hint(key: "esc", label: t("back"))
        ]
    }

    /// What the name being typed is for.
    enum Naming {
        case fresh
        case copy(BuildProfile)
        case rename(String)
    }

    var profiles: [BuildProfile] = []
    var list = ListState()
    var notice = Notice()
    var search = SearchPrompt()
    var naming: Naming?
    var name = TextPrompt()
    /// The profile a delete is waiting on a yes for.
    var confirming: BuildProfile?

    var filtered: [BuildProfile] {
        guard !search.query.isEmpty else { return profiles }
        let q = search.query.lowercased()
        return profiles.filter { $0.name.lowercased().contains(q) }
    }

    func tick(_ ctx: AppContext) {
        // Every frame: edits made on the editor screen land here.
        profiles = ctx.settings.profiles
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if search.open { return search.take(key, list: &list) }
        if naming != nil { return handleNaming(key, ctx: ctx) }
        if let profile = confirming { return handleConfirm(key, profile: profile, ctx: ctx) }

        let visible = filtered
        switch key {
        case .up: list.move(-1, count: visible.count)
        case .down: list.move(1, count: visible.count)
        case .pageUp: list.page(-1, count: visible.count)
        case .pageDown: list.page(1, count: visible.count)
        case .home: list.jump(to: 0, count: visible.count)
        case .end: list.jump(to: visible.count - 1, count: visible.count)
        case .enter:
            guard let profile = visible[safe: list.selected] else { return .none }
            return .push(edit(profile, ctx))
        case .char(let typed):
            command(Keys.latin(typed), visible: visible, ctx: ctx)
        case .esc:
            if search.drop(list: &list) { return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func command(_ letter: Character?, visible: [BuildProfile], ctx: AppContext) {
        switch letter {
        case "/":
            search.open = true
            notice.clear()
        case "n":
            naming = .fresh
            name.text = ""
            notice.clear()
        case "c":
            guard let profile = visible[safe: list.selected] else { return }
            naming = .copy(profile)
            name.text = ctx.settings.uniqueProfileName(profile.name)
            notice.clear()
        case "r":
            guard let profile = visible[safe: list.selected] else { return }
            naming = .rename(profile.id)
            name.text = profile.name
            notice.clear()
        case "d":
            guard let profile = visible[safe: list.selected] else { return }
            guard profiles.count > 1 else {
                notice.say(t("the last profile stays — the build screen opens on one"), error: true)
                return
            }
            confirming = profile
        case "m":
            guard let profile = visible[safe: list.selected] else { return }
            ctx.settings.useProfile(profile.id)
            notice.say(t("the build screen opens on %@", profile.name))
        default: break
        }
    }

    private func edit(_ profile: BuildProfile, _ ctx: AppContext) -> ProfileEditScreen {
        ProfileEditScreen(profile: profile, settings: ctx.settings, hasSeamPatch: ctx.toolchain.mkgmapIsPatched)
    }

    private func handleNaming(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch name.handle(key) {
        case .typing: break
        case .quit: return .quit
        case .cancelled: naming = nil
        case .accepted(let wanted):
            let what = naming
            naming = nil
            switch what {
            case .fresh:
                // From the defaults and the default style, not from the highlighted profile.
                var choices = BuildChoices()
                choices.styleID = ctx.settings.settings.defaultStyleID
                let made = ctx.settings.addProfile(named: wanted, choices: choices)
                profiles = ctx.settings.profiles
                select(made.id)
                guard !saidUnsaved(ctx) else { return .none }
                return .push(edit(made, ctx))
            case .copy(let source):
                let made = ctx.settings.addProfile(
                    named: wanted.isEmpty ? source.name : wanted,
                    choices: source.choices
                )
                profiles = ctx.settings.profiles
                select(made.id)
                if !saidUnsaved(ctx) { notice.say(t("copied to %@", made.name)) }
            case .rename(let id):
                guard !wanted.isEmpty else { return .none }
                ctx.settings.renameProfile(id, to: wanted)
                profiles = ctx.settings.profiles
                select(id)
                if !saidUnsaved(ctx), let now = ctx.settings.profile(id) { notice.say(t("renamed to %@", now.name)) }
            case .none: break
            }
        }
        return .none
    }

    /// Whether the settings file refused the change just made, said in red if so: this run
    /// holds it, the next start will not.
    private func saidUnsaved(_ ctx: AppContext) -> Bool {
        guard let failure = ctx.settings.saveFailure else { return false }
        notice.say(t("could not save the settings: %@", failure.localizedDescription), error: true)
        return true
    }

    private func handleConfirm(_ key: KeyEvent, profile: BuildProfile, ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            let wasCurrent = ctx.settings.currentProfile.id == profile.id
            guard ctx.settings.deleteProfile(profile.id) else {
                // Another kmap deleted it, or left it the last one: the list shows the file.
                profiles = ctx.settings.profiles
                list.jump(to: min(list.selected, filtered.count - 1), count: filtered.count)
                notice.say(
                    profiles.contains(where: { $0.id == profile.id })
                        ? t("the last profile stays — the build screen opens on one")
                        : t("%@ is already gone — another kmap deleted it", profile.name),
                    error: true
                )
                return .none
            }
            profiles = ctx.settings.profiles
            list.jump(to: min(list.selected, filtered.count - 1), count: filtered.count)
            if saidUnsaved(ctx) { return .none }
            guard wasCurrent else {
                notice.say(t("deleted %@", profile.name))
                return .none
            }
            notice.say(
                t("deleted %@ — the build screen now opens on %@", profile.name, ctx.settings.currentProfile.name)
            )
        case .no: confirming = nil
        case .quit: return .quit
        case nil: break
        }
        return .none
    }

    private func select(_ id: String) {
        guard let at = filtered.firstIndex(where: { $0.id == id }) else { return }
        list.selected = at
    }
}
