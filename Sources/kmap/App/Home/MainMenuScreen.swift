import Foundation

/// The landing screen: a short menu on the left, current state on the right.
final class MainMenuScreen: Screen {
    var page: Page { Page(t("menu"), keys: keys) }

    private var keys: [Hint] {
        [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("select")),
            Hint(key: "q", label: t("quit"))
        ]
    }

    struct Item {
        let key: String
        let label: String
        let note: String
        let about: String
        let open: () -> Screen
    }

    private static let menuWidth = 46
    private static let gutter = 3
    private static let leastStatusWidth = 24
    private static let rowHeight = 2

    /// Built each frame, so a change of language takes effect at once.
    private var items: [Item] {
        [
            Item(
                key: "1",
                label: t("New map"),
                note: t("build a map"),
                about: t(
                    "Pick a region, choose what goes into the map, and press Build."
                        + " kmap downloads the data, draws contour lines and shaded relief,"
                        + " and writes an .img file ready for the device."
                ),
                open: { RegionPickerScreen() }
            ),
            Item(
                key: "2",
                label: t("Library"),
                note: t("maps you have already built"),
                about: t(
                    "Every map you have built, with its size and date. From here a map"
                        + " can be shown in the file manager, ready to copy to the device, or"
                        + " deleted when it is no longer needed."
                ),
                open: { LibraryScreen() }
            ),
            Item(
                key: "3",
                label: t("Styles"),
                note: t("how the map looks — TYP files"),
                about: t(
                    "A style decides how the map looks on the screen: colours, fills,"
                        + " icons. Styles can be edited here or taken from another Garmin map."
                        + " Without one the device draws the map in its own default colours."
                ),
                open: { StyleListScreen() }
            ),
            Item(
                key: "4",
                label: t("Profiles"),
                note: t("your saved build settings"),
                about: t(
                    "A profile is a saved set of build settings — one per device, or one"
                        + " per kind of map. Picking a profile fills the whole New map form in"
                        + " one step. The region is chosen each time and is not part of it."
                ),
                open: { ProfilesScreen() }
            ),
            Item(
                key: "5",
                label: t("Zoom plans"),
                note: t("what appears at which zoom"),
                about: t(
                    "A zoom plan sets the zoom level where each kind of feature appears"
                        + " on the device: trails, roads, woodland and so on. The plans that"
                        + " come with kmap are a good starting point; copy one to adjust it."
                ),
                open: { ZoomPlansScreen() }
            ),
            Item(
                key: "6",
                label: t("Toolchain"),
                note: t("mkgmap, the seam patch, elevation data"),
                about: t(
                    "The external programs a build needs: Java, mkgmap and the"
                        + " optional data packs. kmap installs most of this itself and shows"
                        + " the exact command for the rest."
                ),
                open: { ToolchainScreen() }
            ),
            Item(
                key: "7",
                label: t("Settings"),
                note: t("paths, memory, connections"),
                about: t("Folders, memory, download connections, and the language of these screens."),
                open: { SettingsScreen() }
            )
        ]
    }

    private var list = ListState()

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let items = self.items
        switch key.command {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .char("q"), .ctrl("c"), .esc: return .quit
        case .enter:
            guard let item = items[safe: list.selected] else { return .none }
            return .push(item.open())
        case .char(let c) where c.isNumber:
            guard let n = Int(String(c)), let item = items[safe: n - 1] else { return .none }
            list.jump(to: n - 1, count: items.count)
            return .push(item.open())
        default: break
        }
        return .none
    }

    func tick(_ ctx: AppContext) {
        ctx.loadIndexIfNeeded()
        ctx.refreshTools()
        ctx.refreshOverview()
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        s.text(
            rect.x,
            rect.y,
            "OpenStreetMap \(Glyph.arrowRight) Garmin",
            Style(fg: theme.strong, bg: theme.appBg, bold: true)
        )
        s.text(
            rect.x,
            rect.y + 1,
            t("contour lines, DEM, and a style of your choosing"),
            Style(fg: theme.faint, bg: theme.appBg)
        )

        let bodyY = rect.y + 3
        let leftWidth = min(Self.menuWidth, rect.w / 2)
        let left = Rect(x: rect.x, y: bodyY, w: leftWidth, h: rect.h - 3)
        let right = Rect(
            x: rect.x + leftWidth + Self.gutter,
            y: bodyY,
            w: max(0, rect.w - leftWidth - Self.gutter),
            h: rect.h - 3
        )

        let items = self.items
        renderMenu(items, into: s, rect: left, theme: theme)
        if right.w > Self.leastStatusWidth {
            MainMenuStatusPanel(selected: items[safe: list.selected]).draw(into: s, rect: right, ctx: ctx)
        }
    }

    private func renderMenu(_ items: [Item], into s: Surface, rect: Rect, theme: Theme) {
        // Too short for a note under every item: 1 row each, and past that a window that
        // keeps the selected item in view.
        let tall = items.count * Self.rowHeight <= rect.h
        let rowHeight = tall ? Self.rowHeight : 1
        let fits = max(1, rect.h / rowHeight)
        let first = min(max(0, list.selected - fits + 1), max(0, items.count - fits))
        let room = max(0, rect.w - 6)
        for (i, item) in items.enumerated().dropFirst(first) {
            let y = rect.y + (i - first) * rowHeight
            guard y + rowHeight - 1 < rect.maxY else { break }
            let selected = i == list.selected
            let bg = selected ? theme.selectionBg : theme.appBg

            if selected {
                s.fill(Rect(x: rect.x, y: y, w: rect.w, h: rowHeight), Style(fg: theme.text, bg: bg))
                s.vline(rect.x, y, rowHeight, Glyph.bar, Style(fg: theme.accent, bg: bg))
            }
            s.text(
                rect.x + 2,
                y,
                item.key,
                Style(fg: selected ? theme.accent : theme.faint, bg: bg, bold: selected)
            )
            s.text(
                rect.x + 5,
                y,
                truncate(item.label, to: room),
                Style(fg: selected ? theme.selectionFg : theme.text, bg: bg, bold: selected)
            )
            if tall { s.text(rect.x + 5, y + 1, truncate(item.note, to: room), Style(fg: theme.faint, bg: bg)) }
        }
    }
}
