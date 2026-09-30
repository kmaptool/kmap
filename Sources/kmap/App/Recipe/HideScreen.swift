import Foundation

/// Selects the features to leave off the map. Space toggles, typing filters. The choice
/// applies to the next build and is undone by rebuilding without it.
final class HideScreen: Screen {
    var page: Page {
        Page(t("hide on map"), subject: filter.isEmpty ? nil : t("filter"), keys: keys)
    }

    private var keys: [Hint] {
        [
            Hint(key: "space", label: t("toggle")),
            Hint(key: "type", label: t("filter")),
            Hint(key: "^A", label: t("hide all shown")),
            Hint(key: "^N", label: t("show all")),
            Hint(key: "esc", label: t("done"))
        ]
    }

    private enum Row {
        case heading(String)
        case feature(HideableFeature)
    }

    private static let pageRows = 8
    private static let noteColumn = 38
    private static let nameColumn = 6

    private var hidden: Set<String>
    private let onChange: (Set<String>) -> Void
    private var filter = TypedFilter()

    init(hidden: Set<String>, onChange: @escaping (Set<String>) -> Void) {
        self.hidden = hidden
        self.onChange = onChange
    }

    private var matching: [HideableFeature] {
        guard !filter.isEmpty else { return HideableFeature.all }
        // In both languages, and on the id, which is what a profile records.
        return HideableFeature.all.filter {
            filter.matches([$0.name, $0.localizedName, $0.id, $0.category, $0.localizedCategory])
        }
    }

    /// Features under their category heading, in catalogue order.
    private var rows: [Row] {
        let features = matching
        var out: [Row] = []
        for category in HideableFeature.categories {
            let group = features.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            out.append(.heading(category))
            out.append(contentsOf: group.map(Row.feature))
        }
        return out
    }

    /// Skips headings, so the cursor only lands on something toggleable.
    private func step(_ delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        var index = filter.list.selected
        for _ in 0..<rows.count {
            index += delta
            if index < 0 { index = rows.count - 1 }
            if index >= rows.count { index = 0 }
            if case .feature = rows[index] { filter.list.selected = index; return }
        }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let rows = self.rows
        switch key {
        case .up: step(-1, in: rows)
        case .down: step(1, in: rows)
        case .pageUp: for _ in 0..<Self.pageRows { step(-1, in: rows) }
        case .pageDown: for _ in 0..<Self.pageRows { step(1, in: rows) }
        case .char(" "), .enter:
            guard case .feature(let feature)? = rows[safe: filter.list.selected] else { return .none }
            if hidden.contains(feature.id) { hidden.remove(feature.id) } else { hidden.insert(feature.id) }
            onChange(hidden)
        case .ctrl("a"):
            // What the filter shows: "amenity" + ^A hides that group, not the catalogue.
            for feature in matching { hidden.insert(feature.id) }
            onChange(hidden)
        case .ctrl("n"):
            if filter.isEmpty {
                hidden.removeAll()
            } else {
                for feature in matching { hidden.remove(feature.id) }
            }
            onChange(hidden)
        case .backspace, .char, .paste:
            let before = filter.query
            _ = filter.take(key, count: rows.count)
            if filter.query != before { step(1, in: self.rows) }
        case .esc:
            if filter.clear() { step(1, in: self.rows); return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let rows = self.rows
        let y = filter.drawHeader(
            into: s,
            trailing: hidden.isEmpty ? tn("%d feature(s)", HideableFeature.all.count) : tn("%d hidden", hidden.count),
            trailingStyle: Style(fg: hidden.isEmpty ? theme.faint : theme.warn, bg: theme.appBg),
            rect: rect,
            y: rect.y,
            theme: theme
        )

        let visible = max(1, rect.maxY - y - 1)
        guard !rows.isEmpty else {
            s.text(rect.x, y, filter.nothingMatches, Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        // The first row is a heading, which the cursor never rests on.
        filter.list.clamp(count: rows.count, visible: visible)
        if case .heading = rows[filter.list.selected] { step(1, in: rows) }
        let listTop = y
        for index in filter.list.window(count: rows.count, visible: visible) {
            let ry = listTop + index - filter.list.offset
            switch rows[index] {
            case .heading(let name):
                // The catalogue is in English; the display names are translated by id.
                s.sectionRule(
                    rect,
                    ry,
                    HideableNames.category(name),
                    labelStyle: Style(fg: theme.dim, bg: theme.appBg, bold: true),
                    ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
                )
            case .feature(let feature):
                draw(feature, into: s, rect: rect, y: ry, selected: index == filter.list.selected, theme: theme)
            }
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: visible),
            offset: filter.list.offset,
            count: rows.count,
            visible: visible,
            theme: theme
        )

        guard rect.maxY - 1 > listTop else { return }
        s.text(
            rect.x,
            rect.maxY - 1,
            t("kept until you change it · applies to the map and to the custom POI file"),
            Style(fg: theme.faint, bg: theme.appBg),
            limit: rect.w
        )
    }

    private func draw(_ feature: HideableFeature, into s: Surface, rect: Rect, y: Int, selected: Bool, theme: Theme) {
        let isHidden = hidden.contains(feature.id)
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        s.text(
            rect.x + 2,
            y,
            isHidden ? "[\(Glyph.check)]" : "[ ]",
            Style(fg: isHidden ? theme.warn : theme.faint, bg: bg, bold: isHidden)
        )
        // The name stops before the note's column.
        let noteX = rect.x + Self.noteColumn
        s.text(
            rect.x + Self.nameColumn,
            y,
            feature.localizedName,
            Style(fg: isHidden ? theme.warn : theme.text, bg: bg, bold: selected),
            limit: Self.noteColumn - Self.nameColumn - 2
        )
        if !feature.note.isEmpty {
            s.text(noteX, y, truncate(t(feature.note), to: max(0, rect.maxX - noteX)), Style(fg: theme.faint, bg: bg))
        }
    }
}
