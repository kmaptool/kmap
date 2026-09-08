import Foundation

/// The styles kmap can build with: the built-ins and the TYP library.
///
/// A TYP on a mounted drive is never offered in place; importing takes a copy. Letters
/// are commands and `/` starts a search, so typing does not filter the list.
final class StyleListScreen: Screen {
    var page: Page { Page(t("styles"), subject: search.open ? t("search") : nil, keys: keys) }

    private var keys: [Hint] {
        if let asking { return asking.footerHints }
        if search.open {
            return [Hint(key: Glyph.enter, label: t("keep")), Hint(key: "esc", label: t("clear"))]
        }
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if renaming {
            return [Hint(key: Glyph.enter, label: t("rename")), Hint(key: "esc", label: t("cancel"))]
        }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("open")),
                Hint(key: "n", label: t("new")),
                Hint(key: "i", label: t("import")),
                Hint(key: "r", label: t("rename")),
                Hint(key: "d", label: t("delete")),
                Hint(key: "c", label: t("duplicate")),
                Hint(key: "o", label: t("restore the original")),
                Hint(key: "m", label: t("make default")),
                Hint(key: "/", label: t("search")),
                Hint(key: "esc", label: t("back"))]
    }

    private var styles: [MapStyle] = []
    private var list = ListState()
    private var message: String?
    private var messageIsError = false
    private var scanned = false

    private var search = SearchPrompt()
    private var renaming = false
    private var name = TextPrompt()
    /// The style a delete is waiting on a yes for.
    private var confirming: MapStyle?
    /// The overwrite question while it is up, and the style it is about. A modal dialog,
    /// since restoring discards edits; the cursor starts on the answer that changes nothing.
    private var asking: Dialog?
    private var restoring: MapStyle?

    private var filtered: [MapStyle] {
        guard !search.query.isEmpty else { return styles }
        let q = search.query.lowercased()
        return styles.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
        }
    }

    /// Where a style's file is, when it is one kmap may act on.
    private func libraryFile(of style: MapStyle) -> URL? {
        guard let url = style.typURL, TypLibrary.mayWrite(to: url) else { return nil }
        return url
    }

    func tick(_ ctx: AppContext) {
        // The built-ins plus the TYP folder, with no disk scan behind it.
        guard !scanned else { return }
        styles = ctx.styles.styles().list
        scanned = true
    }

    private func reload(_ ctx: AppContext, select url: URL? = nil) {
        ctx.styles.rescanStyles()
        styles = ctx.styles.styles().list
        guard let url,
              let index = styles.firstIndex(where: { $0.typURL?.sameFile(as: url) == true })
        else { return }
        list.selected = index
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if var open = asking {
            switch open.handle(key) {
            case .confirmed:
                asking = nil
                if let style = restoring { restore(style, ctx) }
                restoring = nil
            case .cancelled:
                asking = nil
                restoring = nil
            case .none:
                asking = open
            }
            return .none
        }
        if search.open { return handleSearch(key) }
        if renaming { return handleRename(key, ctx: ctx) }
        if let style = confirming { return handleConfirm(key, style: style, ctx: ctx) }

        let visible = filtered
        switch key {
        case .up: list.move(-1, count: visible.count)
        case .down: list.move(1, count: visible.count)
        case .pageUp: list.move(-10, count: visible.count, wrap: false)
        case .pageDown: list.move(10, count: visible.count, wrap: false)
        case .home: list.jump(to: 0, count: visible.count)
        case .end: list.jump(to: visible.count - 1, count: visible.count)

        case .enter:
            guard let style = visible[safe: list.selected] else { return .none }
            return .push(StyleDetailScreen(style: style))

        case .char(let typed):
            // Matched by the key's position, not its letter, so the commands survive a
            // non-Latin keyboard layout.
            return command(Keys.latin(typed), visible: visible, ctx: ctx)

        case .ctrl("r"):
            reload(ctx)
            say(tn("%d style(s)", styles.count))

        case .esc:
            if !search.query.isEmpty { search.query = ""; list.selected = 0; return .none }
            return .pop

        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// One lettered command, aimed at the selected style where it takes one.
    private func command(_ letter: Character?, visible: [MapStyle],
                         ctx: AppContext) -> Route {
        switch letter {
        case "/":
            search.open = true
            message = nil
        case "n":
            return newStyle(ctx)
        case "i":
            return .push(ImportTypScreen(onImported: { [weak self] in
                self?.scanned = false
            }))
        case "r":
            guard let style = visible[safe: list.selected] else { return .none }
            beginRename(style)
        case "d":
            guard let style = visible[safe: list.selected] else { return .none }
            guard libraryFile(of: style) != nil else {
                say(t("only a style in your library can be deleted"), error: true)
                return .none
            }
            confirming = style
        case "c":
            guard let style = visible[safe: list.selected] else { return .none }
            copyStyle(style, ctx)
        case "o":
            guard let style = visible[safe: list.selected] else { return .none }
            beginRestore(style)
        case "m":
            guard let style = visible[safe: list.selected] else { return .none }
            ctx.settings.update { $0.defaultStyleID = style.id }
            say(t("%@ is now the default", style.name))
        default: break
        }
        return .none
    }

    private func beginRename(_ style: MapStyle) {
        guard libraryFile(of: style) != nil else {
            say(t("only a style in your library can be renamed"), error: true)
            return
        }
        renaming = true
        name.text = style.name
        message = nil
    }

    /// A built-in is copied from its source rather than a file: the copy lands in the
    /// library, editable, and the built-in stays as shipped.
    private func copyStyle(_ style: MapStyle, _ ctx: AppContext) {
        if let shipped = StyleCatalog.shippedPalette(id: style.id) {
            do {
                let copy = try TypLibrary.adopt(
                    source: try StyleCatalog.shippedTypText(of: shipped),
                    named: style.name)
                reload(ctx, select: copy)
                say(t("copied to %@", copy.deletingPathExtension().lastPathComponent))
            } catch {
                say(error.localizedDescription, error: true)
            }
            return
        }
        guard let url = libraryFile(of: style) else {
            say(t("only a style in your library can be copied"), error: true)
            return
        }
        do {
            let copy = try TypLibrary.duplicate(url)
            reload(ctx, select: copy)
            say(t("copied to %@", copy.deletingPathExtension().lastPathComponent))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Restoring throws real work away, so it asks first.
    private func beginRestore(_ style: MapStyle) {
        guard let url = libraryFile(of: style) else {
            say(t("only a style in your library can be restored"), error: true)
            return
        }
        guard TypLibrary.original(of: url) != nil else {
            say(t("this style has no original kept — nothing was imported to go"
                + " back to"), error: true)
            return
        }
        restoring = style
        asking = Dialog(
            title: t("Overwrite"),
            body: [t("%@ will be rewritten from the binary kept when it was"
                   + " imported. Everything changed in it since is lost.", style.name),
                   t("The copy kept at import is not touched, so this can be done"
                   + " again.")],
            detail: [(t("style"), style.name)],
            confirm: t("restore"),
            cancel: t("cancel"),
            tone: .plain)
    }

    private func handleSearch(_ key: KeyEvent) -> Route {
        switch search.handle(key) {
        case .changed, .cleared: list.selected = 0
        case .quit: return .quit
        case .closed, .unchanged: break
        }
        return .none
    }

    private func handleRename(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch name.handle(key) {
        case .typing: break
        case .quit: return .quit
        case .cancelled: renaming = false
        case .accepted(let wanted):
            renaming = false
            guard let style = filtered[safe: list.selected],
                  let url = libraryFile(of: style) else { return .none }
            let wasDefault = ctx.settings.settings.defaultStyleID == style.id
            do {
                let moved = try TypLibrary.rename(url, to: wanted)
                reload(ctx, select: moved)
                // The id is derived from the name, so the default setting is carried
                // across to the new id.
                if wasDefault, let now = styles.first(where: {
                    $0.typURL?.sameFile(as: moved) == true
                }) {
                    ctx.settings.update { $0.defaultStyleID = now.id }
                }
                say(t("renamed to %@", moved.deletingPathExtension().lastPathComponent))
            } catch {
                say(error.localizedDescription, error: true)
            }
        }
        return .none
    }

    private func handleConfirm(_ key: KeyEvent, style: MapStyle, ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            guard let url = libraryFile(of: style) else { return .none }
            let wasDefault = ctx.settings.settings.defaultStyleID == style.id
            do {
                try TypLibrary.delete(url)
                reload(ctx)
                guard wasDefault else {
                    say(t("deleted %@", style.name))
                    return .none
                }
                // Deleting the default moves the setting to another style and reports it,
                // rather than leaving it naming a style that is gone.
                let replacement = styles.first { libraryFile(of: $0) != nil }
                    ?? styles.first { $0.id == "plain" }
                    ?? styles.first
                if let replacement {
                    ctx.settings.update { $0.defaultStyleID = replacement.id }
                    say(t("deleted %@ — it was the default, which is now %@",
                          style.name, replacement.name))
                } else {
                    say(t("deleted %@ — nothing is left to be the default", style.name))
                }
            } catch {
                say(error.localizedDescription, error: true)
            }
        case .no: confirming = nil
        case .quit: return .quit
        case nil: break
        }
        return .none
    }

    private func newStyle(_ ctx: AppContext) -> Route {
        do {
            // The name becomes a file name, so it is not translated.
            let url = try TypLibrary.create(named: "new style")
            reload(ctx, select: url)
            // Matched by resolved path, not URL equality: a library behind a symlink
            // yields two spellings of the same file.
            guard let style = styles.first(where: { $0.typURL?.sameFile(as: url) == true })
            else { return .none }
            return .push(StyleDetailScreen(style: style))
        } catch {
            say(error.localizedDescription, error: true)
            return .none
        }
    }

    /// Rewrites the working copy from the binary kept at import. The kept original is not
    /// touched, so this may be repeated.
    private func restore(_ style: MapStyle, _ ctx: AppContext) {
        guard let url = libraryFile(of: style) else { return }
        do {
            try TypLibrary.restore(url)
            reload(ctx, select: url)
            say(t("%@ is back as it was imported", style.name))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let defaultID = ctx.settings.settings.defaultStyleID
        var y = rect.y

        let intro = t("A style is two things: the rules that turn OSM tags into Garmin types, "
                    + "and a TYP file that says how those types are drawn. kmap ships the "
                    + "rules; the look comes from your library.")
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
            s.textRight(rect.maxX, y, t("%d of %d", shown.count, styles.count),
                        Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - 6)
        list.clamp(count: shown.count, visible: listHeight)

        if shown.isEmpty {
            s.text(rect.x, y, styles.isEmpty ? t("no styles found")
                                             : t("nothing matches \"%@\"", search.query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        let listTop = y
        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let style = shown[safe: index] else { break }
            let isDefault = style.id == defaultID
            let inLibrary = libraryFile(of: style) != nil
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                        text: style.name,
                        trailing: isDefault ? t("default") : (inLibrary ? t("yours") : ""),
                        theme: theme,
                        selected: index == list.selected,
                        leading: isDefault ? "\(Glyph.dot) " : "  ")
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)

        guard let style = shown[safe: list.selected], y + 2 < rect.maxY else { return }
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        for chunk in wrapText(t(style.summary), width: rect.w) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, chunk, Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }
        switch style.origin {
        case .importedTYP(let url), .customDirectory(let url):
            if y < rect.maxY {
                s.text(rect.x, y, truncate(Paths.display(url), to: rect.w),
                       Style(fg: theme.faint, bg: theme.appBg))
            }
        case .builtin:
            break
        }

        drawFooterLine(s, rect: rect, theme: theme)

        // Drawn last, over everything else: the dialog is modal.
        asking?.render(into: s, rect: rect, theme: theme)
    }

    /// Whatever is being asked or said, on the last line.
    private func drawFooterLine(_ s: Surface, rect: Rect, theme: Theme) {
        let y = rect.maxY - 1
        if let confirming {
            s.text(rect.x, y,
                   t("delete %@? the file goes for good  (y/n)", confirming.name),
                   Style(fg: theme.danger, bg: theme.appBg, bold: true))
            return
        }
        if renaming {
            let x = s.text(rect.x, y, t("rename to") + ": ",
                           Style(fg: theme.text, bg: theme.appBg))
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
