import Foundation

/// Named sets of build choices, one per device or kind of map.
///
/// A profile fills the build form in; a field changed there applies to that map only, and
/// a profile is rewritten only from this screen. `/` opens search, leaving letters as keys.
final class ProfilesScreen: Screen {
    var page: Page { Page(t("profiles"), subject: search.open ? t("search") : nil, keys: keys) }

    private var keys: [Hint] {
        if search.open {
            return [Hint(key: Glyph.enter, label: t("keep")), Hint(key: "esc", label: t("clear"))]
        }
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if naming != nil {
            return [Hint(key: Glyph.enter, label: t("accept")), Hint(key: "esc", label: t("cancel"))]
        }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("open")),
                Hint(key: "n", label: t("new")),
                Hint(key: "c", label: t("copy")),
                Hint(key: "r", label: t("rename")),
                Hint(key: "d", label: t("delete")),
                Hint(key: "m", label: t("make current")),
                Hint(key: "/", label: t("search")),
                Hint(key: "esc", label: t("back"))]
    }

    /// What the name being typed at the bottom of the screen is for.
    private enum Naming {
        case fresh
        case copy(BuildProfile)
        case rename(String)
    }

    private var profiles: [BuildProfile] = []
    private var list = ListState()
    private var message: String?
    private var messageIsError = false

    private var search = SearchPrompt()
    private var naming: Naming?
    private var name = TextPrompt()
    /// The profile a delete is waiting on a yes for.
    private var confirming: BuildProfile?

    private var filtered: [BuildProfile] {
        guard !search.query.isEmpty else { return profiles }
        let q = search.query.lowercased()
        return profiles.filter { $0.name.lowercased().contains(q) }
    }

    func tick(_ ctx: AppContext) {
        // Read every frame: edits, renames and copies made on the editor screen land here.
        profiles = ctx.settings.profiles
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if search.open { return handleSearch(key) }
        if naming != nil { return handleNaming(key, ctx: ctx) }
        if let profile = confirming { return handleConfirm(key, profile: profile, ctx: ctx) }

        let visible = filtered
        switch key {
        case .up: list.move(-1, count: visible.count)
        case .down: list.move(1, count: visible.count)
        case .pageUp: list.move(-10, count: visible.count, wrap: false)
        case .pageDown: list.move(10, count: visible.count, wrap: false)
        case .home: list.jump(to: 0, count: visible.count)
        case .end: list.jump(to: visible.count - 1, count: visible.count)

        case .enter:
            guard let profile = visible[safe: list.selected] else { return .none }
            return .push(ProfileEditScreen(profile: profile, settings: ctx.settings,
                                          hasSeamPatch: ctx.toolchain.mkgmapIsPatched))

        case .char(let typed):
            // Keyed by the key's place on the keyboard, not by the character it sends, so
            // the actions survive a non-Latin layout.
            switch Keys.latin(typed) {
            case "/":
                search.open = true
                message = nil

            case "n":
                naming = .fresh
                name.text = ""
                message = nil

            case "c":
                guard let profile = visible[safe: list.selected] else { return .none }
                naming = .copy(profile)
                name.text = ctx.settings.uniqueProfileName(profile.name)
                message = nil

            case "r":
                guard let profile = visible[safe: list.selected] else { return .none }
                naming = .rename(profile.id)
                name.text = profile.name
                message = nil

            case "d":
                guard let profile = visible[safe: list.selected] else { return .none }
                guard profiles.count > 1 else {
                    // The build screen opens on a profile, so one has to remain.
                    say(t("the last profile stays — the build screen opens on one"),
                        error: true)
                    return .none
                }
                confirming = profile

            case "m":
                guard let profile = visible[safe: list.selected] else { return .none }
                ctx.settings.useProfile(profile.id)
                say(t("the build screen opens on %@", profile.name))

            default: break
            }

        case .esc:
            if !search.query.isEmpty { search.query = ""; list.selected = 0; return .none }
            return .pop

        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func handleSearch(_ key: KeyEvent) -> Route {
        switch search.handle(key) {
        case .changed, .cleared: list.selected = 0
        case .quit: return .quit
        case .closed, .unchanged: break
        }
        return .none
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
                // A new profile starts from the built-in defaults and the default style,
                // not from the highlighted profile.
                var choices = BuildChoices()
                choices.styleID = ctx.settings.settings.defaultStyleID
                // An empty name is accepted: `uniqueProfileName` supplies a base.
                let made = ctx.settings.addProfile(named: wanted, choices: choices)
                profiles = ctx.settings.profiles
                select(made.id)
                return .push(ProfileEditScreen(profile: made, settings: ctx.settings,
                                          hasSeamPatch: ctx.toolchain.mkgmapIsPatched))
            case .copy(let source):
                let made = ctx.settings.addProfile(named: wanted.isEmpty ? source.name
                                                                         : wanted,
                                                   choices: source.choices)
                profiles = ctx.settings.profiles
                select(made.id)
                say(t("copied to %@", made.name))
            case .rename(let id):
                guard !wanted.isEmpty else { return .none }
                ctx.settings.renameProfile(id, to: wanted)
                profiles = ctx.settings.profiles
                select(id)
                if let now = ctx.settings.profile(id) { say(t("renamed to %@", now.name)) }
            case .none:
                break
            }
        }
        return .none
    }

    private func handleConfirm(_ key: KeyEvent, profile: BuildProfile,
                               ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            let wasCurrent = ctx.settings.currentProfile.id == profile.id
            guard ctx.settings.deleteProfile(profile.id) else { return .none }
            profiles = ctx.settings.profiles
            list.jump(to: min(list.selected, filtered.count - 1), count: filtered.count)
            guard wasCurrent else {
                say(t("deleted %@", profile.name))
                return .none
            }
            // Deleting the profile in use changes which one the next build starts from,
            // so the replacement is named.
            say(t("deleted %@ — the build screen now opens on %@",
                  profile.name, ctx.settings.currentProfile.name))
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

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let currentID = ctx.settings.currentProfile.id
        var y = rect.y

        let intro = t("A profile is a saved set of build settings. Pick one on the New "
                    + "map screen and every field fills in from it. Anything changed after "
                    + "that applies to the current map only — the profile itself stays as "
                    + "it was.")
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        let shown = filtered
        if search.open || !search.query.isEmpty {
            let fx = s.text(rect.x, y, t("search") + ": ", Style(fg: theme.dim, bg: theme.appBg))
            let end = s.text(fx, y, search.query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
            if search.open { s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg)) }
            s.textRight(rect.maxX, y, t("%d of %d", shown.count, profiles.count),
                        Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - 8)
        list.clamp(count: shown.count, visible: listHeight)

        if shown.isEmpty {
            s.text(rect.x, y, t("nothing matches \"%@\"", search.query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        let listTop = y
        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let profile = shown[safe: index] else { break }
            let isCurrent = profile.id == currentID
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                        text: profile.name,
                        trailing: isCurrent ? t("in use") : "",
                        theme: theme,
                        selected: index == list.selected,
                        leading: isCurrent ? "\(Glyph.dot) " : "  ")
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)

        guard let profile = shown[safe: list.selected], y + 2 < rect.maxY else { return }
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        for line in ProfilesScreen.summary(of: profile.choices) {
            guard y < rect.maxY - 1 else { break }
            s.text(rect.x, y, truncate(line, to: rect.w), Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }

        drawFooterLine(s, rect: rect, theme: theme)
    }

    /// A few lines describing a profile without opening it: only the choices that differ
    /// from one profile to the next.
    static func summary(of choices: BuildChoices) -> [String] {
        var parts: [String] = []
        parts.append(choices.contours
                     ? t("contours every %d m", choices.contourInterval)
                     : t("no contours"))
        parts.append(choices.demLayer ? t("with the DEM layer") : t("no DEM"))
        parts.append(LevelsProfile.all.first { $0.id == choices.levelsID }?.name ?? "")
        let labels = LabelLanguage.all.first { $0.id == choices.labelLanguageID } ?? .local
        parts.append(t("labels: %@", labels.name))
        parts.append(choices.codePage == 0
                     ? t("code page by region")
                     : t("code page %d", choices.codePage))

        var lines = [parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")]
        lines.append(t("style: %@", choices.styleID))
        lines.append(SplitMode(settingsID: choices.splitMode, count: choices.parts).label)
        if !choices.hiddenFeatures.isEmpty {
            lines.append(tn("%d feature(s) left off the map", choices.hiddenFeatures.count))
        }
        return lines
    }

    /// Whatever is being asked or said, on the last line.
    private func drawFooterLine(_ s: Surface, rect: Rect, theme: Theme) {
        let y = rect.maxY - 1
        if let confirming {
            s.text(rect.x, y, t("delete %@?  (y/n)", confirming.name),
                   Style(fg: theme.danger, bg: theme.appBg, bold: true))
            return
        }
        if let naming {
            let label: String
            switch naming {
            case .fresh: label = t("name it")
            case .copy: label = t("copy as")
            case .rename: label = t("rename to")
            }
            let x = s.text(rect.x, y, label + ": ", Style(fg: theme.text, bg: theme.appBg))
            let end = s.text(x, y, name.text, Style(fg: theme.strong, bg: theme.appBg, bold: true))
            s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
            return
        }
        if let message {
            s.text(rect.x, y, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }
    }
}
