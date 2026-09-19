import Foundation

/// The order polygons are painted in. Level 1 is painted first and every later level
/// covers it. The arrows move a polygon a level at a time, Enter takes a level by
/// number. Polygons missing from the table are listed first: they are not drawn at all.
final class DrawOrderScreen: Screen {
    var page: Page {
        Page(t("draw order"), subject: document.style.name, keys: keys)
    }

    private var keys: [Hint] {
        if typing {
            return [
                Hint(key: Glyph.enter, label: t("move it there")),
                Hint(key: "esc", label: t("cancel"))
            ]
        }
        var hints = [Hint(key: "↑↓", label: t("move"))]
        if document.isEditable {
            hints.append(Hint(key: "←→", label: t("a level down / up")))
            hints.append(Hint(key: Glyph.enter, label: t("type a level")))
        }
        hints.append(Hint(key: "esc", label: t("back")))
        return hints
    }

    /// One line of the list.
    enum Row: Equatable {
        case caption(String)
        /// Level nil: missing from the table.
        case polygon(code: Int, level: Int?)

        var code: Int? {
            if case .polygon(let code, _) = self { return code }
            return nil
        }
    }

    private var document: StyleDocument
    private var list = ListState()
    private var typing = false
    private var level = TextPrompt()
    private var message: String?
    private var messageIsError = false

    /// Rebuilt after an edit, not per frame: the rules are read for the tags.
    private var cachedRows: [Row] = []
    private var tagsByCode: [Int: String] = [:]
    private var rowsStale = true

    init(document: StyleDocument) {
        self.document = document
    }

    // MARK: The list

    /// Grouped by level, levels sorted, so a table written out of order still reads as
    /// one group per level. The missing polygons come first.
    var rows: [Row] {
        if rowsStale {
            cachedRows = buildRows()
            rowsStale = false
        }
        return cachedRows
    }

    private func buildRows() -> [Row] {
        guard let source = document.source else { return [] }
        var out: [Row] = []

        let forgotten = source.polygonsMissingFromDrawOrder
        if !forgotten.isEmpty {
            out.append(.caption(t("not in the draw order — never drawn")))
            out.append(contentsOf: forgotten.map { .polygon(code: $0, level: nil) })
        }

        // Stable: within a level the file's order is kept.
        let ordered = source.drawOrder.enumerated().sorted {
            ($0.element.level, $0.offset) < ($1.element.level, $1.offset)
        }.map(\.element)
        var level = Int.min
        for entry in ordered {
            if entry.level != level {
                level = entry.level
                out.append(.caption(t("level %d", level)))
            }
            out.append(.polygon(code: entry.code, level: entry.level))
        }

        tagsByCode = [:]
        for row in document.rows(.polygon) where row.isEmitted {
            tagsByCode[row.code] = row.tags.first
        }
        return out
    }

    /// One above the highest level the other polygons reach: a second empty level on
    /// top would add nothing.
    private func ceiling(for code: Int) -> Int {
        (document.source?.drawOrder.filter { $0.code != code }.map(\.level).max() ?? 0) + 1
    }

    private var selectedRow: Row? { rows[safe: list.selected] }

    /// Moves the cursor, skipping captions in the direction of travel.
    private func move(_ delta: Int, wrap: Bool = true) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        list.move(delta, count: rows.count, wrap: wrap)
        settle(forward: delta > 0)
    }

    /// Steps off a caption onto the nearest polygon, wrapping round.
    private func settle(forward: Bool) {
        let rows = self.rows
        guard rows.contains(where: { $0.code != nil }) else { return }
        while rows[safe: list.selected]?.code == nil {
            list.move(forward ? 1 : -1, count: rows.count)
        }
    }

    // MARK: Keys

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if typing { return handleTyping(key) }
        switch key.command {
        case .up, .char("k"): move(-1)
        case .down, .char("j"): move(1)
        case .pageUp: move(-10, wrap: false)
        case .pageDown: move(10, wrap: false)
        case .home: list.jump(to: 0, count: rows.count); settle(forward: true)
        case .end: list.jump(to: rows.count - 1, count: rows.count); settle(forward: false)
        case .left: shift(-1)
        case .right: shift(1)
        case .enter: beginTyping()
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// One level down or up. A missing polygon goes in at level 1 either way.
    private func shift(_ delta: Int) {
        guard case .polygon(let code, let level)? = selectedRow else { return }
        guard let level else { return moveLevel(of: code, to: 1) }
        let wanted = level + delta
        guard wanted >= 1 else {
            say(t("level 1 is painted first — there is nothing under it"), error: true)
            return
        }
        guard wanted <= ceiling(for: code) else {
            say(t("level %d is already on top of everything", level), error: true)
            return
        }
        moveLevel(of: code, to: wanted)
    }

    private func beginTyping() {
        guard let row = selectedRow, row.code != nil else { return }
        guard document.isEditable else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        typing = true
        level = TextPrompt()
        message = nil
    }

    private func handleTyping(_ key: KeyEvent) -> Route {
        switch level.handle(key) {
        case .typing: break
        case .quit: return .quit
        case .cancelled: typing = false
        case .accepted(let text):
            typing = false
            guard case .polygon(let code, _)? = selectedRow else { break }
            let top = ceiling(for: code)
            guard let wanted = Int(text), (1...top).contains(wanted) else {
                say(t("a level is a number from 1 to %d", top), error: true)
                break
            }
            moveLevel(of: code, to: wanted)
        }
        return .none
    }

    /// Rewrites the entry, re-reads the file and keeps the cursor on the polygon.
    private func moveLevel(of code: Int, to wanted: Int) {
        guard document.isEditable, let source = document.source,
            let url = document.sourceURL
        else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        do {
            let edited = try TypEdit.setDrawOrderLevel(in: source, code: code, to: wanted)
            try TypLibrary.save(edited, to: url)
            document = StyleDocument.load(document.style)
            rowsStale = true
            if let index = rows.firstIndex(where: { $0.code == code }) {
                list.jump(to: index, count: rows.count)
            }
            say(t("%1$@ is now on level %2$d", TypeMeaning.hex(code), wanted))
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
        let rows = self.rows
        guard let source = document.source, !rows.isEmpty else {
            s.text(
                rect.x,
                rect.y,
                t("this TYP declares no draw order"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            return
        }

        var y = rect.y
        let intro = t(
            "Polygons are painted level by level: level 1 first, every later"
                + " level on top of it. Within a level the order does not matter."
        )
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        // The last line holds the message or the prompt.
        let visible = max(1, rect.maxY - y - 1)
        if rows[safe: list.selected]?.code == nil { settle(forward: true) }
        list.clamp(count: rows.count, visible: visible)

        for (i, row) in rows.dropFirst(list.offset).prefix(visible).enumerated() {
            let line = y + i
            switch row {
            case .caption(let caption):
                s.sectionRule(
                    rect,
                    line,
                    caption,
                    labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                    ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
                )
            case .polygon(let code, let level):
                draw(
                    code: code,
                    drawn: level != nil,
                    in: source,
                    into: s,
                    rect: Rect(x: rect.x, y: rect.y, w: rect.w - 1, h: rect.h),
                    y: line,
                    theme: theme,
                    selected: list.offset + i == list.selected
                )
            }
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w, h: visible),
            offset: list.offset,
            count: rows.count,
            visible: visible,
            theme: theme
        )

        let bottom = rect.maxY - 1
        if typing {
            let x = s.text(
                rect.x,
                bottom,
                t("move to level") + ": ",
                Style(fg: theme.text, bg: theme.appBg)
            )
            let end = s.text(
                x,
                bottom,
                level.text,
                Style(fg: theme.strong, bg: theme.appBg, bold: true)
            )
            s.put(end, bottom, "▏", Style(fg: theme.accent, bg: theme.appBg))
        } else if let message {
            s.text(
                rect.x,
                bottom,
                truncate(message, to: rect.w),
                Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg)
            )
        }
    }

    /// Code, day colour, name, and at the right the tag the rules draw it for.
    private func draw(
        code: Int,
        drawn: Bool,
        in source: TypSource,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme,
        selected: Bool
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        s.text(
            rect.x,
            y,
            selected ? "\(Glyph.arrowRight) " : "  ",
            Style(fg: theme.accent, bg: bg)
        )

        var x = s.text(
            rect.x + 2,
            y,
            String(format: "0x%02x", code),
            Style(fg: theme.dim, bg: bg)
        )
        let section = source.section(.polygon, code)
        x = Widgets.swatch(
            s,
            x: x + 2,
            y: y,
            colour: section?.representativeColours.day,
            width: 3,
            theme: theme
        )

        let name =
            (L10n.current == .ru ? section?.russianLabel : nil)
            ?? section?.englishLabel
        let text =
            name
            ?? (drawn
                ? t("not styled by this TYP — the device draws its own")
                : t("no name"))
        var limit = rect.maxX - x - 2
        if let tag = tagsByCode[code], rect.w > 60 {
            let width = min(tag.count, rect.w / 3)
            s.textRight(
                rect.maxX,
                y,
                truncate(tag, to: width),
                Style(fg: theme.faint, bg: bg)
            )
            limit -= width + 2
        }
        s.text(
            x + 2,
            y,
            text,
            Style(fg: name == nil ? theme.faint : theme.text, bg: bg),
            limit: max(0, limit)
        )
    }
}
