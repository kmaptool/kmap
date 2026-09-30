import Foundation

/// The order polygons are painted in: level 1 first, every later level over it. Arrows
/// move a polygon a level at a time, Enter takes a level by number. Polygons missing
/// from the table are listed first: they are not drawn at all.
final class DrawOrderScreen: Screen {
    var page: Page { Page(t("draw order"), subject: document.style.name, keys: keys) }

    private var keys: [Hint] {
        if typing {
            return [Hint(key: Glyph.enter, label: t("move it there")), Hint(key: "esc", label: t("cancel"))]
        }
        var hints = [Hint(key: "↑↓", label: t("move"))]
        if document.isEditable {
            hints.append(Hint(key: "←→", label: t("a level down / up")))
            hints.append(Hint(key: Glyph.enter, label: t("type a level")))
        }
        hints.append(Hint(key: "esc", label: t("back")))
        return hints
    }

    enum Row: Equatable {
        case caption(String)
        /// Level nil: missing from the table.
        case polygon(code: Int, level: Int?)

        var code: Int? {
            if case .polygon(let code, _) = self { return code }
            return nil
        }
    }

    var document: StyleDocument
    var list = ListState()
    var typing = false
    var level = TextPrompt()
    var notice = Notice()

    /// Rebuilt after an edit, not per frame: the rules are read for the tags.
    private var cachedRows: [Row] = []
    var tagsByCode: [Int: String] = [:]
    private var rowsStale = true

    init(document: StyleDocument) {
        self.document = document
    }

    // MARK: The list

    /// Grouped by level, levels sorted; the missing polygons come first.
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
        // Within a level the file's order is kept.
        let ordered = source.drawOrder.enumerated()
            .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element)
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

    /// One above the highest level the other polygons reach.
    private func ceiling(for code: Int) -> Int {
        (document.source?.drawOrder.filter { $0.code != code }.map(\.level).max() ?? 0) + 1
    }

    private var selectedRow: Row? { rows[safe: list.selected] }

    private func move(_ delta: Int, wrap: Bool = true) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        list.move(delta, count: rows.count, wrap: wrap)
        settle(forward: delta > 0)
    }

    /// Steps off a caption onto the nearest polygon, wrapping round.
    func settle(forward: Bool) {
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
        case .pageUp: move(-ListState.pageStep, wrap: false)
        case .pageDown: move(ListState.pageStep, wrap: false)
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
            notice.say(t("level 1 is painted first — there is nothing under it"), error: true)
            return
        }
        guard wanted <= ceiling(for: code) else {
            notice.say(t("level %d is already on top of everything", level), error: true)
            return
        }
        moveLevel(of: code, to: wanted)
    }

    private func beginTyping() {
        guard let row = selectedRow, row.code != nil else { return }
        guard document.isEditable else {
            notice.say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        typing = true
        level = TextPrompt()
        notice.clear()
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
                notice.say(t("a level is a number from 1 to %d", top), error: true)
                break
            }
            moveLevel(of: code, to: wanted)
        }
        return .none
    }

    /// Rewrites the entry, re-reads the file and keeps the cursor on the polygon.
    private func moveLevel(of code: Int, to wanted: Int) {
        guard document.isEditable, let source = document.source, let url = document.sourceURL else {
            notice.say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        do {
            try TypLibrary.save(try TypEdit.setDrawOrderLevel(in: source, code: code, to: wanted), to: url)
            document = StyleDocument.load(document.style)
            rowsStale = true
            if let index = rows.firstIndex(where: { $0.code == code }) {
                list.jump(to: index, count: rows.count)
            }
            notice.say(t("%1$@ is now on level %2$d", TypeMeaning.hex(code), wanted))
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }
}
