import Foundation

/// A searchable list of styles, pushed from the build form: TYPs found inside installed
/// maps run the list to dozens of entries.
final class StylePickerScreen: Screen {
    var page: Page {
        Page(t("choose a style"), subject: filter.isEmpty ? nil : t("search"), keys: keys)
    }

    private var keys: [Hint] {
        [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("choose")),
            Hint(key: "type", label: t("filter")),
            Hint(key: "esc", label: t("cancel"))
        ]
    }

    private static let detailRows = 4
    private static let summaryLines = 2

    private let styles: [MapStyle]
    private let current: MapStyle
    private let onPick: (MapStyle) -> Void
    private var filter = TypedFilter()

    init(styles: [MapStyle], current: MapStyle, onPick: @escaping (MapStyle) -> Void) {
        self.styles = styles
        self.current = current
        self.onPick = onPick
        if let index = styles.firstIndex(where: { $0.id == current.id }) {
            filter.list.selected = index
        }
    }

    private var filtered: [MapStyle] {
        guard !filter.isEmpty else { return styles }
        return styles.filter { filter.matches([$0.name, $0.id, $0.summary]) }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let visible = filtered
        if filter.take(key, count: visible.count) { return .none }
        switch key {
        case .enter:
            guard let style = visible[safe: filter.list.selected] else { return .none }
            onPick(style)
            return .pop
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: return .none
        }
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let visible = filtered
        let bodyY = filter.drawHeader(
            into: s,
            trailing: t("%d of %d", visible.count, styles.count),
            trailingStyle: Style(fg: theme.faint, bg: theme.appBg),
            rect: rect,
            y: rect.y,
            theme: theme
        )
        let listHeight = max(1, rect.h - 2 - Self.detailRows)
        guard listHeight > 0 else { return }

        if visible.isEmpty {
            s.text(rect.x, bodyY, filter.nothingMatches, Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        for index in filter.list.window(count: visible.count, visible: listHeight) {
            let style = visible[index]
            let y = bodyY + index - filter.list.offset
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: style.name,
                trailing: style.hasTYP ? t("family %d", style.familyID) : t("no TYP"),
                theme: theme,
                selected: index == filter.list.selected,
                leading: style.id == current.id ? "\(Glyph.dot) " : "  "
            )
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: bodyY, w: rect.w, h: listHeight),
            offset: filter.list.offset,
            count: visible.count,
            visible: listHeight,
            theme: theme
        )

        guard let style = visible[safe: filter.list.selected] else { return }
        var y = bodyY + listHeight
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        for chunk in wrapText(style.summary, width: rect.w).prefix(Self.summaryLines) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, chunk, Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }
        if case .importedTYP(let url) = style.origin, y < rect.maxY {
            s.text(rect.x, y, truncate(url.path, to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
        }
    }
}
