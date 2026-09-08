import Foundation

/// Selects the features to leave off the map. Space toggles, typing filters. The choice
/// applies to the next build and is undone by rebuilding without it.
final class HideScreen: Screen {
    var page: Page {
        Page(t("hide on map"), subject: query.isEmpty ? nil : t("filter"), keys: keys)
    }

    private var keys: [Hint] {
        [Hint(key: "space", label: t("toggle")),
         Hint(key: "type", label: t("filter")),
         Hint(key: "^A", label: t("hide all shown")),
         Hint(key: "^N", label: t("show all")),
         Hint(key: "esc", label: t("done"))]
    }

    /// A flattened row: either a category heading or a feature.
    private enum Row {
        case heading(String)
        case feature(HideableFeature)
    }

    private var hidden: Set<String>
    private let onChange: (Set<String>) -> Void
    private var list = ListState()
    private var query = ""

    init(hidden: Set<String>, onChange: @escaping (Set<String>) -> Void) {
        self.hidden = hidden
        self.onChange = onChange
    }

    private var matching: [HideableFeature] {
        guard !query.isEmpty else { return HideableFeature.all }
        let q = query.lowercased()
        return HideableFeature.all.filter {
            // Matched in both languages, and on the id, which is what a profile records.
            $0.name.lowercased().contains(q)
                || $0.localizedName.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
                || $0.localizedCategory.lowercased().contains(q)
        }
    }

    /// Features grouped under their category heading, in catalogue order.
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

    /// Skips headings so the cursor only ever lands on something toggleable.
    private func step(_ delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        var index = list.selected
        for _ in 0..<rows.count {
            index += delta
            if index < 0 { index = rows.count - 1 }
            if index >= rows.count { index = 0 }
            if case .feature = rows[index] { list.selected = index; return }
        }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let rows = self.rows
        switch key {
        case .up: step(-1, in: rows)
        case .down: step(1, in: rows)
        case .pageUp: for _ in 0..<8 { step(-1, in: rows) }
        case .pageDown: for _ in 0..<8 { step(1, in: rows) }
        case .char(" "), .enter:
            guard case .feature(let feature)? = rows[safe: list.selected] else { return .none }
            if hidden.contains(feature.id) { hidden.remove(feature.id) } else { hidden.insert(feature.id) }
            onChange(hidden)
        case .ctrl("a"):
            // Acts on what the filter currently shows, so "amenity" + ^A hides that group
            // rather than the whole catalogue.
            for feature in matching { hidden.insert(feature.id) }
            onChange(hidden)
        case .ctrl("n"):
            if query.isEmpty {
                hidden.removeAll()
            } else {
                for feature in matching { hidden.remove(feature.id) }
            }
            onChange(hidden)
        case .backspace:
            if !query.isEmpty { query.removeLast(); list.selected = 0; step(1, in: self.rows) }
        case .char(let c):
            query.append(c)
            list.selected = 0
            step(1, in: self.rows)
        case .esc:
            if !query.isEmpty { query = ""; list.selected = 0; step(1, in: self.rows); return .none }
            return .pop
        case .ctrl("c"):
            return .quit
        default: break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let rows = self.rows
        var y = rect.y

        // Filter field.
        let x = s.text(rect.x, y, t("filter") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(x, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        s.textRight(rect.maxX, y,
                    hidden.isEmpty ? tn("%d feature(s)", HideableFeature.all.count)
                                   : tn("%d hidden", hidden.count),
                    Style(fg: hidden.isEmpty ? theme.faint : theme.warn, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        let visible = max(1, rect.maxY - y - 1)
        guard !rows.isEmpty else {
            s.text(rect.x, y, t("nothing matches \"%@\"", query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        list.clamp(count: rows.count, visible: visible)

        for i in 0..<min(visible, rows.count - list.offset) {
            let index = list.offset + i
            let row = rows[index]
            let ry = y + i

            switch row {
            case .heading(let name):
                // The catalogue is generated from mkgmap rule lines and is in English; the
                // display names are translated beside it, keyed by id. See HideableNames.
                s.sectionRule(rect, ry, HideableNames.category(name),
                              labelStyle: Style(fg: theme.dim, bg: theme.appBg, bold: true),
                              ruleStyle: Style(fg: theme.rule, bg: theme.appBg))

            case .feature(let feature):
                let selected = index == list.selected
                let isHidden = hidden.contains(feature.id)
                let bg = selected ? theme.selectionBg : theme.appBg
                s.fill(Rect(x: rect.x, y: ry, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))

                s.text(rect.x + 2, ry, isHidden ? "[\(Glyph.check)]" : "[ ]",
                       Style(fg: isHidden ? theme.warn : theme.faint, bg: bg, bold: isHidden))
                // The name owns its column and stops before the note's, so a long name
                // cannot run into the note.
                let noteX = rect.x + 38
                s.text(rect.x + 6, ry, feature.localizedName,
                       Style(fg: isHidden ? theme.warn : theme.text, bg: bg, bold: selected),
                       limit: noteX - rect.x - 8)
                if !feature.note.isEmpty {
                    s.text(noteX, ry, truncate(t(feature.note), to: max(0, rect.maxX - noteX)),
                           Style(fg: theme.faint, bg: bg))
                }
            }
        }

        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: visible),
                           offset: list.offset, count: rows.count, visible: visible, theme: theme)

        guard rect.maxY - 1 > y else { return }
        s.text(rect.x, rect.maxY - 1,
               t("kept until you change it · applies to the map and to the custom POI file"),
               Style(fg: theme.faint, bg: theme.appBg), limit: rect.w)
    }
}
