import Foundation

/// The styles kmap can build with: the built-ins and the TYP library. Letters are
/// commands and `/` starts a search.
final class StyleListScreen: Screen {
    var page: Page { Page(t("styles"), subject: search.subject, keys: keys) }

    private var keys: [Hint] {
        if let asking { return asking.footerHints }
        if search.open { return search.hints }
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if renaming {
            return [Hint(key: Glyph.enter, label: t("rename")), Hint(key: "esc", label: t("cancel"))]
        }
        return [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("open")),
            Hint(key: "n", label: t("new")),
            Hint(key: "i", label: t("import")),
            Hint(key: "r", label: t("rename")),
            Hint(key: "d", label: t("delete")),
            Hint(key: "c", label: t("duplicate")),
            Hint(key: "o", label: t("restore the original")),
            Hint(key: "m", label: t("make default")),
            Hint(key: "/", label: t("search")),
            Hint(key: "esc", label: t("back"))
        ]
    }

    var styles: [MapStyle] = []
    var list = ListState()
    var notice = Notice()
    var scanned = false
    var search = SearchPrompt()
    var renaming = false
    var name = TextPrompt()
    /// The style a delete is waiting on a yes for.
    var confirming: MapStyle?
    /// The overwrite question, about the style being restored.
    var asking: Question<MapStyle>?

    var filtered: [MapStyle] {
        guard !search.query.isEmpty else { return styles }
        let q = search.query.lowercased()
        return styles.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }
    }

    /// Where a style's file is, when it is one kmap may act on.
    func libraryFile(of style: MapStyle) -> URL? {
        guard let url = style.typURL, TypLibrary.mayWrite(to: url) else { return nil }
        return url
    }

    func tick(_ ctx: AppContext) {
        guard !scanned else { return }
        styles = ctx.styles.styles().list
        scanned = true
    }

    func reload(_ ctx: AppContext, select url: URL? = nil) {
        ctx.styles.rescanStyles()
        styles = ctx.styles.styles().list
        guard let url else { return }
        // The cursor counts the list as shown, with the search applied; a style the
        // search hides is shown by clearing it.
        if !filtered.contains(where: { $0.typURL?.sameFile(as: url) == true }) { search.query = "" }
        guard let index = filtered.firstIndex(where: { $0.typURL?.sameFile(as: url) == true }) else { return }
        list.selected = index
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let (answer, style) = asking.take(key) {
            if answer == .confirmed { restore(style, ctx) }
            return .none
        }
        if search.open { return search.take(key, list: &list) }
        if renaming { return handleRename(key, ctx: ctx) }
        if let style = confirming { return handleConfirm(key, style: style, ctx: ctx) }

        let visible = filtered
        switch key {
        case .up: list.move(-1, count: visible.count)
        case .down: list.move(1, count: visible.count)
        case .pageUp: list.page(-1, count: visible.count)
        case .pageDown: list.page(1, count: visible.count)
        case .home: list.jump(to: 0, count: visible.count)
        case .end: list.jump(to: visible.count - 1, count: visible.count)
        case .enter:
            guard let style = visible[safe: list.selected] else { return .none }
            return .push(StyleDetailScreen(style: style))
        case .char(let typed):
            return command(Keys.latin(typed), visible: visible, ctx: ctx)
        case .ctrl("r"):
            reload(ctx)
            notice.say(tn("%d style(s)", styles.count))
        case .esc:
            if search.drop(list: &list) { return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }
}
