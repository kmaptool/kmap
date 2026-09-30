import Foundation

/// Every type code a style deals in: the meaning lives in the rule set, the drawing in
/// the TYP, and neither file refers to the other. Shown side by side.
final class TypeBrowserScreen: Screen {
    var page: Page {
        Page("\(document.style.name) · \(kind.plural)", subject: search.subject, keys: keys)
    }

    private var keys: [Hint] {
        if let asking { return asking.footerHints }
        if search.open { return search.hints }
        return [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: document.isEditable ? t("change") : t("inspect")),
            Hint(key: "←→", label: t("points/lines/polygons")),
            Hint(key: "a", label: t("add a section")),
            Hint(key: "d", label: t("delete the section")),
            Hint(key: "x", label: t("reassign a rule")),
            Hint(key: "l", label: russian ? t("english") : t("russian")),
            Hint(key: "p", label: showingDetail ? t("hide the preview") : t("preview")),
            Hint(key: "/", label: t("search")),
            Hint(key: "esc", label: t("back"))
        ]
    }

    var document: StyleDocument
    var kind: MapElementKind
    var list = ListState()
    var search = SearchPrompt()
    /// Which of a section's own labels to show: a property of the style, not of the
    /// interface language.
    var russian = true
    var notice = Notice()
    /// The pane under the list costs it about a third of its rows, so it starts closed.
    var showingDetail = false
    /// The confirmation before a section is deleted, about the row it is for.
    var asking: Question<StyleTypeRow>?
    /// Folds opened, by the first code of the run.
    var expandedFolds: Set<Int> = []

    /// Rebuilt only when the kind changes.
    private var cachedRows: [StyleTypeRow] = []
    private var cachedKind: MapElementKind?

    init(document: StyleDocument, kind: MapElementKind = .point) {
        self.document = document
        self.kind = kind
    }

    var rows: [StyleTypeRow] {
        if cachedKind != kind {
            cachedRows = document.rows(kind)
            cachedKind = kind
        }
        return cachedRows
    }

    /// The rows as listed: searched, or with runs of anonymous codes folded.
    var folding: TypeRowFolding {
        guard search.query.isEmpty else {
            let q = search.query.lowercased()
            return TypeRowFolding(
                rows: rows.filter { row in
                    row.hex.contains(q)
                        || row.name(preferringRussian: russian).lowercased().contains(q)
                        || row.section?.englishLabel?.lowercased().contains(q) == true
                        || row.tags.contains { $0.lowercased().contains(q) }
                },
                spans: [:]
            )
        }
        return TypeRowFolding.fold(rows, kind: kind, expanded: expandedFolds)
    }

    var visible: [StyleTypeRow] { folding.rows }
    var selectedRow: StyleTypeRow? { visible[safe: list.selected] }

    /// Opens a fold when the selected row stands for one; says whether it did.
    private func unfoldIfFolded() -> Bool {
        guard let row = selectedRow, folding.spans[row.code] != nil else { return false }
        expandedFolds.insert(row.code)
        return true
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let (answer, row) = asking.take(key) {
            if answer == .confirmed { removeSection(row) }
            return .none
        }
        if search.open { return search.take(key, list: &list) }

        let count = visible.count
        switch key {
        case .up: list.move(-1, count: count)
        case .down: list.move(1, count: count)
        case .pageUp: list.page(-1, count: count)
        case .pageDown: list.page(1, count: count)
        case .home: list.jump(to: 0, count: count)
        case .end: list.jump(to: count - 1, count: count)
        case .left: step(-1)
        case .right, .tab: step(1)
        case .enter:
            if unfoldIfFolded() { return .none }
            guard let row = selectedRow else { return .none }
            guard row.isStyled else {
                notice.say(t("this TYP has no section for %@ — press a to add one", row.hex), error: true)
                return .none
            }
            return .push(editor(for: row))
        case .char(let typed):
            return command(Keys.latin(typed), ctx)
        case .esc:
            if search.drop(list: &list) { return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// By the key's place on the keyboard, so the commands survive a non-Latin layout.
    private func command(_ letter: Character?, _ ctx: AppContext) -> Route {
        switch letter {
        case "/":
            search.open = true
            notice.clear()
        case "a":
            if unfoldIfFolded() { return .none }
            return addSection(ctx)
        case "d":
            if unfoldIfFolded() { return .none }
            askToRemoveSection()
        case "x":
            if unfoldIfFolded() { return .none }
            return reassign()
        case "l": russian.toggle()
        case "p": showingDetail.toggle()
        default: break
        }
        return .none
    }

    func editor(for row: StyleTypeRow) -> TypeEditScreen {
        TypeEditScreen(style: document.style, kind: kind, code: row.code) { [weak self] in self?.reload() }
    }

    /// The rule set, not the TYP: a code drawn correctly can still be emitted for the
    /// wrong thing. On a free code, the inverse: which feature to bind here.
    private func reassign() -> Route {
        guard let row = selectedRow else { return .none }
        let reloaded: () -> Void = { [weak self] in self?.reload() }
        guard row.isEmitted else {
            return .push(ReassignScreen(document: document, kind: kind, bindingTo: row.code, onReassigned: reloaded))
        }
        return .push(ReassignScreen(document: document, kind: kind, code: row.code, onReassigned: reloaded))
    }

    /// Re-reads the file after an edit.
    func reload() {
        document = StyleDocument.load(document.style)
        cachedKind = nil
    }

    /// Moves between points, lines and polygons, keeping the search filter.
    private func step(_ delta: Int) {
        let kinds = MapElementKind.allCases
        guard let index = kinds.firstIndex(of: kind) else { return }
        kind = kinds[(index + delta + kinds.count) % kinds.count]
        list = ListState()
    }
}
