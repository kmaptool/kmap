import Foundation

/// The landing screen: a short menu on the left, current state on the right.
final class MainMenuScreen: Screen {
    var page: Page { Page(t("menu"), keys: keys) }
    private var keys: [Hint] {
        [Hint(key: "↑↓", label: t("move")),
         Hint(key: Glyph.enter, label: t("select")),
         Hint(key: "q", label: t("quit"))]
    }

    private struct Item {
        let key: String
        let label: String
        let note: String
    }

    /// Built afresh each frame, so a change of language takes effect at once.
    private var items: [Item] {
        [Item(key: "1", label: t("New map"), note: t("build a map")),
         Item(key: "2", label: t("Library"), note: t("maps you have already built")),
         Item(key: "3", label: t("Styles"), note: t("how the map looks — TYP files")),
         Item(key: "4", label: t("Profiles"), note: t("your saved build settings")),
         Item(key: "5", label: t("Zoom plans"), note: t("what appears at which zoom")),
         Item(key: "6", label: t("Toolchain"), note: t("mkgmap, the seam patch, elevation data")),
         Item(key: "7", label: t("Settings"), note: t("paths, memory, connections")),
         Item(key: "8", label: t("Help"), note: t("how kmap works"))]
    }

    private var list = ListState()

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch key.command {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .char("q"), .ctrl("c"): return .quit
        case .esc: return .quit
        case .enter: return activate(list.selected, ctx)
        case .char(let c) where c.isNumber:
            guard let n = Int(String(c)), n >= 1, n <= items.count else { return .none }
            list.jump(to: n - 1, count: items.count)
            return activate(n - 1, ctx)
        default: break
        }
        return .none
    }

    private func activate(_ index: Int, _ ctx: AppContext) -> Route {
        switch index {
        case 0: return .push(RegionPickerScreen())
        case 1: return .push(LibraryScreen())
        case 2: return .push(StyleListScreen())
        case 3: return .push(ProfilesScreen())
        case 4: return .push(ZoomPlansScreen())
        case 5: return .push(ToolchainScreen())
        case 6: return .push(SettingsScreen())
        case 7: return .push(HelpScreen())
        default: return .none
        }
    }

    func tick(_ ctx: AppContext) {
        ctx.loadIndexIfNeeded()
        ctx.refreshTools()
        ctx.refreshOverview()
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme

        // Wordmark.
        s.text(rect.x, rect.y, "OpenStreetMap \(Glyph.arrowRight) Garmin",
               Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.text(rect.x, rect.y + 1, t("contour lines, DEM, and a style of your choosing"),
               Style(fg: theme.faint, bg: theme.appBg))

        let bodyY = rect.y + 3
        let leftWidth = min(46, rect.w / 2)
        let left = Rect(x: rect.x, y: bodyY, w: leftWidth, h: rect.h - 3)
        let right = Rect(x: rect.x + leftWidth + 3, y: bodyY,
                         w: max(0, rect.w - leftWidth - 3), h: rect.h - 3)

        renderMenu(s, rect: left, theme: theme)
        if right.w > 24 { renderStatus(s, rect: right, ctx: ctx) }
    }

    private func renderMenu(_ s: Surface, rect: Rect, theme: Theme) {
        for (i, item) in items.enumerated() {
            let y = rect.y + i * 2
            guard y + 1 < rect.maxY else { break }
            let selected = i == list.selected
            let bg = selected ? theme.selectionBg : theme.appBg

            if selected {
                s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 2), Style(fg: theme.text, bg: bg))
                s.vline(rect.x, y, 2, Glyph.bar, Style(fg: theme.accent, bg: bg))
            }

            s.text(rect.x + 2, y, item.key,
                   Style(fg: selected ? theme.accent : theme.faint, bg: bg, bold: selected))
            s.text(rect.x + 5, y, item.label,
                   Style(fg: selected ? theme.selectionFg : theme.text, bg: bg, bold: selected))
            s.text(rect.x + 5, y + 1, item.note,
                   Style(fg: theme.faint, bg: bg))
        }
    }

    private func renderStatus(_ s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        s.sectionRule(rect, y, t("state"),
                      labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 2

        func line(_ label: String, _ value: String, tone: Color? = nil) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, label, Style(fg: theme.faint, bg: theme.appBg), limit: 14)
            s.text(rect.x + 14, y, truncate(value, to: max(0, rect.w - 14)),
                   Style(fg: tone ?? theme.text, bg: theme.appBg))
            y += 1
        }

        // Region index
        switch ctx.indexState {
        case .idle, .loading:
            line(t("regions"), t("loading %@", String(Widgets.spinner(ctx.frame))),
                 tone: theme.dim)
        case .ready:
            line(t("regions"), t("%d available", ctx.index.regions.count), tone: theme.ok)
        case .failed(let message):
            line(t("regions"), truncate(message, to: rect.w - 15), tone: theme.danger)
        }

        // Read from the sampled snapshot, never probed inline.
        if !ctx.toolsProbed {
            line(t("toolchain"), t("checking %@", String(Widgets.spinner(ctx.frame))),
                 tone: theme.dim)
        } else {
            let ready = ctx.tools.filter(\.isReady).count
            line(t("toolchain"), t("%d/%d ready", ready, ctx.tools.count),
                 tone: ready == ctx.tools.count ? theme.ok : theme.warn)

            for tool in ctx.tools where !tool.isReady {
                guard y < rect.maxY else { break }
                s.text(rect.x + 14, y, "\(Glyph.cross) " + t("%@ missing", tool.name),
                       Style(fg: theme.warn, bg: theme.appBg))
                y += 1
            }
        }

        line(t("output"), Paths.display(ctx.settings.settings.outputURL))

        let overview = ctx.overview
        line(t("cache"), overview.cachedExtracts == 0
             ? t("empty")
             : tn("%d extract(s)", overview.cachedExtracts)
                 + " · \(Fmt.bytes(overview.cachedBytes))")
        line(t("built maps"), overview.builtMaps == 0 ? t("none yet") : "\(overview.builtMaps)")

        // A description of the entry under the cursor.
        y += 1
        guard y < rect.maxY - 1, let item = items[safe: list.selected] else { return }
        s.sectionRule(rect, y, item.label.lowercased(),
                      labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 2
        for chunk in wrapText(Self.about(item.key), width: rect.w) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
    }

    /// The descriptive paragraph for a menu entry.
    static func about(_ key: String) -> String {
        switch key {
        case "1":
            return t("Pick a region, choose what goes into the map, and press Build."
                   + " kmap downloads the data, draws contour lines and shaded relief,"
                   + " and writes an .img file ready for the device.")
        case "2":
            return t("Every map you have built, with its size and date. From here a map"
                   + " can be shown in the file manager, ready to copy to the device, or"
                   + " deleted when it is no longer needed.")
        case "3":
            return t("A style decides how the map looks on the screen: colours, fills,"
                   + " icons. Styles can be edited here or taken from another Garmin map."
                   + " Without one the device draws the map in its own default colours.")
        case "4":
            return t("A profile is a saved set of build settings — one per device, or one"
                   + " per kind of map. Picking a profile fills the whole New map form in"
                   + " one step. The region is chosen each time and is not part of it.")
        case "5":
            return t("A zoom plan sets the zoom level where each kind of feature appears"
                   + " on the device: trails, roads, woodland and so on. The plans that"
                   + " come with kmap are a good starting point; copy one to adjust it.")
        case "6":
            return t("The external programs a build needs: Java, mkgmap and the"
                   + " optional data packs. kmap installs most of this itself and shows"
                   + " the exact command for the rest.")
        case "7":
            return t("Folders, memory, download connections, and the language of these"
                   + " screens.")
        default:
            return t("How a build works step by step, what the settings mean, and what"
                   + " the command line adds.")
        }
    }
}