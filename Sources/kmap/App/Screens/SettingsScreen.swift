import Foundation

/// Preferences that persist between builds.
final class SettingsScreen: Screen {
    var page: Page { Page(t("settings"), keys: keys) }

    private var keys: [Hint] {
        if picking != nil {
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("choose")),
                    Hint(key: "esc", label: t("cancel"))]
        }
        if let editing {
            var hints = [Hint(key: Glyph.enter, label: t("accept"))]
            if FilePicker.isAvailable, editing.wants != nil {
                hints.append(Hint(key: "^O", label: t("browse")))
            }
            hints.append(Hint(key: "esc", label: t("cancel")))
            return hints
        }
        return [Hint(key: "↑↓", label: t("field")),
                Hint(key: "←→", label: t("change")),
                Hint(key: Glyph.enter, label: t("edit")),
                Hint(key: "esc", label: t("save & back"))]
    }

    /// The visible fields. The four login fields serve srtm1 and alos1, which exist only
    /// while pyhgtmap is installed, and are dropped without it.
    private func fields(_ ctx: AppContext) -> [Field] {
        guard ctx.toolchain.findPyhgtmap() == nil else { return Field.allCases }
        return Field.allCases.filter {
            $0 != .usgsUser && $0 != .usgsPassword && $0 != .jaxaUser && $0 != .jaxaPassword
        }
    }

    enum Field: Int, CaseIterable {
        case uiLanguage
        case output, work, connections, heap, maxNodes, keepWork
        case usgsUser, usgsPassword, jaxaUser, jaxaPassword
        case mkgmapJar, javaBinary, clearCache, clearElevation

        var label: String {
            switch self {
            case .uiLanguage: return t("Language")
            case .output: return t("Output folder")
            case .work: return t("Work folder")
            case .usgsUser: return t("USGS login")
            case .usgsPassword: return t("USGS password")
            case .jaxaUser: return t("JAXA login")
            case .jaxaPassword: return t("JAXA password")
            case .connections: return t("Download streams")
            case .heap: return t("Java heap")
            case .maxNodes: return t("Nodes per tile")
            case .keepWork: return t("Keep work files")
            case .mkgmapJar: return "mkgmap.jar"
            case .javaBinary: return "java"
            case .clearCache: return t("Cached extracts")
            case .clearElevation: return t("Cached elevation")
            }
        }

        /// What a file dialog would be looking for on this field's behalf, or nil for the
        /// fields that hold something other than a path.
        var wants: FilePicker.Wanted? {
            switch self {
            case .output, .work: return .directory
            case .mkgmapJar: return .file(extensions: ["jar"])
            case .javaBinary: return .file(extensions: [])
            default: return nil
            }
        }

        var help: String {
            switch self {
            case .uiLanguage:
                // Kept short: the help text is drawn beside the value, leaving 56 columns
                // on an 80-column terminal.
                return t("the interface, not the map — labels are a build choice")
            case .output: return t("finished maps, each build in its own dated folder")
            case .work: return t("scratch space during a build; emptied when it finishes")
            case .usgsUser:
                return t("ers.cr.usgs.gov/register — unlocks srtm1, 30 m instead of 90 m")
                    + SettingsScreen.verdictNote(.srtm)
            case .usgsPassword:
                return t("kept in ~/.pyhgtmap/config.yaml, readable only by you")
            case .jaxaUser:
                return t("eorc.jaxa.jp/ALOS/en/aw3d30 — unlocks alos1, also 30 m")
                    + SettingsScreen.verdictNote(.alos)
            case .jaxaPassword:
                return t("same file, same permissions")
            case .connections: return t("parallel byte-range connections per download")
            case .heap: return t("memory handed to mkgmap; 0 means auto")
            case .maxNodes: return t("upper limit on one map tile; the default suits most machines")
            case .keepWork: return t("keep intermediate tiles and contours after a build")
            case .mkgmapJar: return t("leave empty and kmap finds it on its own")
            case .javaBinary: return t("leave empty and kmap finds it on its own")
            case .clearCache: return t("downloaded .osm.pbf extracts kept for reuse")
            case .clearElevation:
                return t("downloaded elevation data; cleared, it is downloaded again")
            }
        }
    }

    private var list = ListState()
    private var editing: Field?
    private var draft = ""
    /// The last verdict on this login, as a suffix for the field's help line. Empty where
    /// there are no credentials or none has been asked for yet.
    nonisolated static func verdictNote(_ service: ElevationLogins.Service) -> String {
        let login = ElevationLogins.load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return "" }
        switch ElevationLogins.check(service)?.verdict {
        case .valid: return "  ·  " + t("the login works")
        case .rejected: return "  ·  " + t("refused — the source is not offered")
        case .unreachable: return "  ·  " + t("could not be checked")
        case nil: return ""
        }
    }

    private var message: String?
    /// Logins being asked about right now, by service id, so a row can say so.
    private var checking: Set<String> = []
    /// The open dropdown: which field, what it offers, and where the cursor sits in it.
    /// Every field with a fixed set of answers has one.
    private var picking: (field: Field, labels: [String], at: Int)?
    /// The row the field with the open dropdown is drawn on, so the list hangs under it.
    private var pickerRow: Int?

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let fields = fields(ctx)

        if let field = editing {
            switch key {
            case .ctrl("o"):
                // The system file dialog, for the fields that name a path.
                if let wanted = field.wants,
                   let chosen = FilePicker.choose(wanted, startingAt: Paths.expand(draft),
                                                  prompt: field.label) {
                    draft = chosen.path
                }
            case .enter:
                commit(field, ctx)
                editing = nil
            case .esc:
                editing = nil
            case .backspace:
                if !draft.isEmpty { draft.removeLast() }
            case .char(let c): draft.append(c)
            case .paste(let text): draft += text.replacingOccurrences(of: "\n", with: "")
            default: break
            }
            return .none
        }

        if var open = picking {
            switch key {
            case .up, .char("k"):
                open.at = (open.at - 1 + open.labels.count) % open.labels.count
                picking = open
            case .down, .char("j"), .tab:
                open.at = (open.at + 1) % open.labels.count
                picking = open
            case .enter, .char(" "):
                picking = nil
                choose(open.field, at: open.at, ctx)
            case .esc, .left, .char("h"), .ctrl("c"):
                picking = nil
            default: break
            }
            return .none
        }

        switch key.command {
        case .up, .char("k"): list.move(-1, count: fields.count)
        case .down, .char("j"): list.move(1, count: fields.count)
        case .left: adjust(fields[safe: list.selected], by: -1, ctx)
        case .right: adjust(fields[safe: list.selected], by: 1, ctx)
        case .esc:
            ctx.settings.save()
            return .pop
        case .ctrl("c"): return .quit
        case .enter:
            guard let field = fields[safe: list.selected] else { return .none }
            switch field {
            case .output, .work, .usgsUser, .usgsPassword, .jaxaUser, .jaxaPassword,
                 .mkgmapJar, .javaBinary:
                editing = field
                draft = currentText(field, ctx)
            case .clearCache:
                clearCache(ctx)
                ctx.refreshOverview(force: true)
            case .clearElevation:
                clearElevationCache(ctx)
                ctx.refreshOverview(force: true)
            default:
                if let open = dropdown(field, ctx) {
                    picking = (field, open.labels, open.at)
                } else {
                    adjust(field, by: 1, ctx)
                }
            }
        default: break
        }
        return .none
    }

    private func currentText(_ field: Field, _ ctx: AppContext) -> String {
        let s = ctx.settings.settings
        switch field {
        case .output: return s.outputDirectory
        case .work: return s.workDirectory
        case .usgsUser: return ElevationLogins.load(.srtm).user
        case .usgsPassword: return ElevationLogins.load(.srtm).password
        case .jaxaUser: return ElevationLogins.load(.alos).user
        case .jaxaPassword: return ElevationLogins.load(.alos).password
        case .mkgmapJar: return s.mkgmapJar
        case .javaBinary: return s.javaBinary
        default: return ""
        }
    }

    private func commit(_ field: Field, _ ctx: AppContext) {
        let value = draft.trimmingCharacters(in: .whitespaces)
        ctx.settings.update { settings in
            switch field {
            case .output:
                if !value.isEmpty { settings.outputDirectory = value }
            case .work:
                settings.workDirectory = value.isEmpty ? Paths.work.path : value
            case .usgsUser:
                let current = ElevationLogins.load(.srtm)
                ElevationLogins.save(.srtm, user: value, password: current.password)
            case .usgsPassword:
                let current = ElevationLogins.load(.srtm)
                ElevationLogins.save(.srtm, user: current.user, password: value)
            case .jaxaUser:
                let current = ElevationLogins.load(.alos)
                ElevationLogins.save(.alos, user: value, password: current.password)
            case .jaxaPassword:
                let current = ElevationLogins.load(.alos)
                ElevationLogins.save(.alos, user: current.user, password: value)
            case .mkgmapJar: settings.mkgmapJar = value
            case .javaBinary: settings.javaBinary = value
            default: break
            }
        }
        message = t("saved")

        // A login is verified as soon as it changes; the verdict decides whether srtm and
        // alos are offered at all.
        switch field {
        case .usgsUser, .usgsPassword: verifyLogin(.srtm)
        case .jaxaUser, .jaxaPassword: verifyLogin(.alos)
        default: break
        }
    }

    /// Asks the service whether the stored credentials work, and reports the verdict.
    private func verifyLogin(_ service: ElevationLogins.Service) {
        let login = ElevationLogins.load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return }
        checking.insert(service.rawValue)
        message = t("%@ — checking the login…", service.displayName)
        Task { [weak self] in
            let verdict = await ElevationLogins.verify(service)
            await MainActor.run {
                guard let self else { return }
                self.checking.remove(service.rawValue)
                switch verdict {
                case .valid: self.message = t("%@ — the login works", service.displayName)
                case .rejected:
                    self.message = t("%@ refused these credentials", service.displayName)
                case .unreachable:
                    self.message = t("%@ did not answer — the login is left as it was",
                                     service.displayName)
                }
            }
        }
    }

    /// The values a field offers and the index of its current one, or nil where the answer
    /// is free text. The same set the arrow keys walk.
    private func dropdown(_ field: Field, _ ctx: AppContext) -> (labels: [String], at: Int)? {
        let settings = ctx.settings.settings
        switch field {
        case .uiLanguage:
            return (Lang.allCases.map(\.nativeName),
                    Lang.allCases.firstIndex(of: L10n.current) ?? 0)
        case .connections:
            return ((1...16).map { "\($0)" },
                    max(0, min(15, settings.downloadConnections - 1)))
        case .heap:
            let labels = Self.heapChoices.map {
                $0 == 0 ? t("auto (%d GB)", settings.resolvedHeapGB) : "\($0) GB"
            }
            return (labels, Self.heapChoices.firstIndex(of: settings.javaHeapGB) ?? 0)
        case .maxNodes:
            return (Self.nodeChoices.map { "\($0 / 1000)k" },
                    Self.nodeChoices.firstIndex(of: settings.maxNodesPerTile) ?? 2)
        case .keepWork:
            return ([t("off"), t("on")], settings.keepWorkFiles ? 1 : 0)
        default:
            return nil
        }
    }

    /// Heap sizes in GB; 0 means derive it from the machine's memory.
    static let heapChoices = [0, 2, 4, 6, 8, 12, 16, 20, 24, 32, 48, 64]
    /// Nodes per tile: smaller tiles build faster and there are more of them.
    static let nodeChoices = [800_000, 1_200_000, 1_600_000, 2_000_000, 2_400_000]

    private func choose(_ field: Field, at index: Int, _ ctx: AppContext) {
        message = nil
        if field == .uiLanguage {
            if let language = Lang.allCases[safe: index] { use(language, ctx) }
            return
        }
        ctx.settings.update { s in
            switch field {
            case .connections: s.downloadConnections = max(1, min(16, index + 1))
            case .heap: s.javaHeapGB = Self.heapChoices[safe: index] ?? 0
            case .maxNodes: s.maxNodesPerTile = Self.nodeChoices[safe: index] ?? 1_600_000
            case .keepWork: s.keepWorkFiles = index == 1
            default: break
            }
        }
    }

    /// `dropdown` and `choose`, reachable without driving the screen through key events.
    func dropdownForTesting(_ field: Field, _ ctx: AppContext) -> (labels: [String], at: Int)? {
        dropdown(field, ctx)
    }

    func chooseForTesting(_ field: Field, at index: Int, _ ctx: AppContext) {
        choose(field, at: index, ctx)
    }

    private func adjust(_ field: Field?, by delta: Int, _ ctx: AppContext) {
        guard let field else { return }
        message = nil

        // Applied at once rather than on leaving the screen, so the labels redraw in the
        // language being chosen.
        if field == .uiLanguage {
            let all = Lang.allCases
            let index = all.firstIndex(of: L10n.current) ?? 0
            use(all[((index + delta) % all.count + all.count) % all.count], ctx)
            return
        }

        ctx.settings.update { s in
            switch field {
            case .connections: s.downloadConnections = max(1, min(16, s.downloadConnections + delta))
            case .heap:
                let index = Self.heapChoices.firstIndex(of: s.javaHeapGB) ?? 0
                s.javaHeapGB = Self.heapChoices[
                    max(0, min(Self.heapChoices.count - 1, index + delta))]
            case .maxNodes:
                let index = Self.nodeChoices.firstIndex(of: s.maxNodesPerTile) ?? 2
                s.maxNodesPerTile = Self.nodeChoices[
                    max(0, min(Self.nodeChoices.count - 1, index + delta))]
            case .keepWork: s.keepWorkFiles.toggle()
            default: break
            }
        }
    }

    /// Switches the interface language and saves it, redrawing the labels at once.
    private func use(_ language: Lang, _ ctx: AppContext) {
        L10n.use(language, in: ctx.settings)
        message = t("saved")
    }

    private func clearCache(_ ctx: AppContext) {
        let files = FileTools.contents(of: Paths.pbfCache)
        let bytes = files.reduce(Int64(0)) { $0 + FileTools.size(of: $1) }
        FileTools.emptyDirectory(Paths.pbfCache)
        message = tn("cleared %d file(s), %@", files.count, Fmt.bytes(bytes))
    }

    private func clearElevationCache(_ ctx: AppContext) {
        let before = AppContext.Overview.Elevation.sample()
        FileTools.emptyDirectory(Paths.hgtCache)
        message = tn("cleared %d tile(s), %@", before.tiles, Fmt.bytes(before.bytes))
    }

    func tick(_ ctx: AppContext) {
        ctx.refreshOverview()
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let settings = ctx.settings.settings
        let fields = fields(ctx)
        list.clamp(count: fields.count, visible: rect.h)

        var y = rect.y
        for (i, field) in fields.enumerated() {
            guard y + 1 < rect.maxY else { break }
            let selected = i == list.selected
            let value: String

            switch field {
            case .uiLanguage:
                value = L10n.current.nativeName
            case .output:
                value = editing == .output ? draft + "▏" : Paths.display(settings.outputURL)
            case .work:
                value = editing == .work ? draft + "▏" : Paths.display(settings.workURL)
            case .usgsUser, .jaxaUser:
                let service: ElevationLogins.Service = field == .usgsUser ? .srtm : .alos
                let user = ElevationLogins.load(service).user
                value = editing == field ? draft + "▏"
                    : (user.isEmpty ? t("not set — 3 arc-second data only") : user)
            case .usgsPassword, .jaxaPassword:
                let service: ElevationLogins.Service = field == .usgsPassword ? .srtm : .alos
                let stored = ElevationLogins.load(service).password
                value = editing == field ? draft + "▏"
                    : (stored.isEmpty ? t("not set")
                       : String(repeating: "•", count: min(12, stored.count)))
            case .connections:
                value = "\(settings.downloadConnections)"
            case .heap:
                value = settings.javaHeapGB == 0
                    ? t("auto (%d GB)", settings.resolvedHeapGB)
                    : "\(settings.javaHeapGB) GB"
            case .maxNodes:
                value = "\(settings.maxNodesPerTile / 1000)k"
            case .keepWork:
                value = settings.keepWorkFiles ? t("on") : t("off")
            case .mkgmapJar:
                value = editing == .mkgmapJar ? draft + "▏"
                    : (settings.mkgmapJar.isEmpty
                       ? (ctx.toolchain.findMkgmap().map { Paths.display($0.url) } ?? t("not found"))
                       : settings.mkgmapJar)
            case .javaBinary:
                value = editing == .javaBinary ? draft + "▏"
                    : (settings.javaBinary.isEmpty
                       ? (ctx.toolchain.findJava()?.path ?? t("not found"))
                       : settings.javaBinary)
            case .clearCache:
                let overview = ctx.overview
                value = overview.cachedExtracts == 0 ? t("empty")
                    : tn("%d file(s)", overview.cachedExtracts)
                        + " · \(Fmt.bytes(overview.cachedBytes)) — " + t("⏎ to clear")
            case .clearElevation:
                let cache = ctx.overview.elevation
                value = cache.tiles == 0 ? t("empty")
                    : tn("%d tile(s)", cache.tiles) + " · \(Fmt.bytes(cache.bytes))"
                        + " · \(cache.sources.joined(separator: " ")) — " + t("⏎ to clear")
            }

            Widgets.field(s, rect: rect, y: y, label: field.label, value: value,
                          theme: theme, labelWidth: Layout.fieldLabel, selected: selected)
            if field == picking?.field { pickerRow = y }
            y += 1
            s.text(rect.x + 20, y, field.help, Style(fg: theme.faint, bg: theme.appBg),
                   limit: max(0, rect.w - 20))
            y += 1
        }

        if let message, y < rect.maxY {
            s.text(rect.x + 2, y, message, Style(fg: theme.ok, bg: theme.appBg))
        }

    }

    /// Draws the open dropdown over the screen, anchored to its field's row.
    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        guard let open = picking, let row = pickerRow else { return }
        Widgets.optionList(s, within: rect, anchorRow: row,
                           options: open.labels, at: open.at,
                           theme: ctx.theme, indent: 20)
    }
}
