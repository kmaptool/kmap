import Foundation

/// A searchable list of styles, pushed from the build form. Searchable rather than cycled,
/// since TYPs found inside installed maps run the list to dozens of entries.
final class StylePickerScreen: Screen {
    var page: Page {
        Page(t("choose a style"), subject: query.isEmpty ? nil : t("search"), keys: keys)
    }

    private var keys: [Hint] {
        [Hint(key: "↑↓", label: t("move")),
         Hint(key: Glyph.enter, label: t("choose")),
         Hint(key: "type", label: t("filter")),
         Hint(key: "esc", label: t("cancel"))]
    }

    private let styles: [MapStyle]
    private let current: MapStyle
    private let onPick: (MapStyle) -> Void
    private var list = ListState()
    private var query = ""

    init(styles: [MapStyle], current: MapStyle, onPick: @escaping (MapStyle) -> Void) {
        self.styles = styles
        self.current = current
        self.onPick = onPick
        if let index = styles.firstIndex(where: { $0.id == current.id }) {
            list.selected = index
        }
    }

    private var filtered: [MapStyle] {
        guard !query.isEmpty else { return styles }
        let q = query.lowercased()
        return styles.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
        }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let visible = filtered
        switch key {
        case .up: list.move(-1, count: visible.count)
        case .down: list.move(1, count: visible.count)
        case .pageUp: list.move(-10, count: visible.count, wrap: false)
        case .pageDown: list.move(10, count: visible.count, wrap: false)
        case .home: list.jump(to: 0, count: visible.count)
        case .end: list.jump(to: visible.count - 1, count: visible.count)
        case .backspace:
            if !query.isEmpty { query.removeLast(); list.selected = 0 }
        case .char(let c):
            query.append(c)
            list.selected = 0
        case .paste(let text):
            query += text.replacingOccurrences(of: "\n", with: "")
        case .enter:
            guard let style = visible[safe: list.selected] else { return .none }
            onPick(style)
            return .pop
        case .esc:
            return .pop
        case .ctrl("c"):
            return .quit
        default:
            break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let visible = filtered

        // Filter field.
        let x = s.text(rect.x, rect.y, t("filter") + ": ",
                       Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(x, rect.y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, rect.y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        s.textRight(rect.maxX, rect.y, t("%d of %d", visible.count, styles.count),
                    Style(fg: theme.faint, bg: theme.appBg))
        s.hline(rect.x, rect.y + 1, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))

        let bodyY = rect.y + 2
        let detailHeight = 4
        let listHeight = max(1, rect.h - 2 - detailHeight)
        guard listHeight > 0 else { return }

        if visible.isEmpty {
            s.text(rect.x, bodyY, t("nothing matches \"%@\"", query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        list.clamp(count: visible.count, visible: listHeight)
        let count = min(listHeight, visible.count - list.offset)
        for i in 0..<count {
            let index = list.offset + i
            guard let style = visible[safe: index] else { break }
            let y = bodyY + i
            let isCurrent = style.id == current.id
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                        y: y,
                        text: style.name,
                        trailing: style.hasTYP ? t("family %d", style.familyID) : t("no TYP"),
                        theme: theme,
                        selected: index == list.selected,
                        leading: isCurrent ? "\(Glyph.dot) " : "  ")
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: bodyY, w: rect.w, h: listHeight),
                           offset: list.offset, count: visible.count,
                           visible: listHeight, theme: theme)

        // Detail for the highlighted entry.
        guard let style = visible[safe: list.selected] else { return }
        var y = bodyY + listHeight
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        for chunk in wrapText(style.summary, width: rect.w).prefix(2) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, chunk, Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }
        if case .importedTYP(let url) = style.origin, y < rect.maxY {
            s.text(rect.x, y, truncate(url.path, to: rect.w),
                   Style(fg: theme.faint, bg: theme.appBg))
        }
    }
}
