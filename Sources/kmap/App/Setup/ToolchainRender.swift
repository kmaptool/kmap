import Foundation

/// Drawing the toolchain: three rows per tool, the message, and the log under them.
extension ToolchainScreen {
    private static let rowHeight = 3
    private static let detailColumn = 22
    private static let leastNoteRoom = 8

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        // Wrapped, not clipped: the path makes the line longer than a narrow window.
        var y = s.paragraph(
            t("A map needs Java and mkgmap. Everything kmap installs lives under %@.", Paths.display(Paths.root)),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        let tools = tools(ctx)
        if tools.isEmpty {
            s.text(
                rect.x,
                y,
                t("checking %@", String(Widgets.spinner(ctx.frame))),
                Style(fg: theme.dim, bg: theme.appBg)
            )
            return
        }
        // The message has its rows kept, wrapped whole: a question whose key is cut off,
        // or not drawn at all, would still take that key.
        let said = message.map { wrapText($0, width: max(1, rect.w - 2)) } ?? []
        let visible = max(1, (rect.maxY - y - said.count) / Self.rowHeight)
        for i in list.window(count: tools.count, visible: visible) {
            guard y + 2 < rect.maxY - said.count else { break }
            draw(tools[i], into: s, rect: rect, y: y, selected: i == list.selected, ctx: ctx)
            y += Self.rowHeight
        }

        for line in said where y < rect.maxY {
            s.text(rect.x + 2, y, line, Style(fg: theme.warn, bg: theme.appBg))
            y += 1
        }

        let lines = log.snapshot()
        guard !lines.isEmpty, y + 2 < rect.maxY else { return }
        y += 1
        s.sectionRule(
            rect,
            y,
            t("log"),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 1
        Widgets.logPane(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w, h: max(0, rect.maxY - y)),
            lines: lines,
            theme: theme
        )
    }

    /// Name and detail, then the install's progress or its status and note, then its path.
    private func draw(_ tool: ToolStatus, into s: Surface, rect: Rect, y: Int, selected: Bool, ctx: AppContext) {
        let theme = ctx.theme
        let bg = selected ? theme.selectionBg : theme.appBg
        let job = queue.running[tool.id]
        let waiting = queue.isWaiting(tool.id)

        if selected {
            s.fill(Rect(x: rect.x, y: y, w: rect.w, h: Self.rowHeight), Style(fg: theme.text, bg: bg))
            s.vline(rect.x, y, Self.rowHeight, Glyph.bar, Style(fg: theme.accent, bg: bg))
        }

        let (marker, tone): (String, Color) = {
            if job != nil { return (String(Widgets.spinner(ctx.frame)), theme.accent) }
            if waiting { return (String(Glyph.dot), theme.dim) }
            switch tool.state {
            case .ready: return (String(Glyph.check), theme.ok)
            case .missing: return (String(Glyph.cross), theme.warn)
            case .broken: return ("!", theme.danger)
            }
        }()
        s.text(rect.x + 2, y, marker, Style(fg: tone, bg: bg))
        s.text(rect.x + 4, y, tool.name, Style(fg: theme.strong, bg: bg, bold: true))
        s.text(
            rect.x + Self.detailColumn,
            y,
            tool.detail,
            Style(fg: theme.faint, bg: bg),
            limit: max(0, rect.w - Self.detailColumn - 2)
        )

        if let job {
            InstallProgressRow.draw(
                s,
                x: rect.x + 4,
                y: y + 1,
                width: rect.w - 6,
                progress: job.progress,
                theme: theme,
                bg: bg
            )
            return
        }

        let status =
            waiting
            ? waitingNote(for: tool.id, ctx)
            : (tool.isReady ? (tool.version ?? t("ready")) : t("not installed"))
        let after = s.text(
            rect.x + 4,
            y + 1,
            truncate(status, to: rect.w - 6),
            Style(fg: tool.isReady ? theme.dim : theme.warn, bg: bg)
        )
        // A newer pack, or the tool's own note, beside the status.
        let room = rect.maxX - after - 4
        if !waiting, let news = ctx.packNews[tool.id] {
            let said = t("newer one published %@ — press u", news.describedShortly)
            if room > Self.leastNoteRoom {
                s.text(after + 1, y + 1, truncate("\(Glyph.dot) \(said)", to: room), Style(fg: theme.accent, bg: bg))
            }
        } else if tool.isReady, let note = tool.note, room > Self.leastNoteRoom {
            s.text(after + 1, y + 1, truncate("\(Glyph.dot) \(note)", to: room), Style(fg: theme.warn, bg: bg))
        }

        if let third = tool.path ?? tool.note {
            s.text(rect.x + 4, y + 2, truncate(third, to: rect.w - 6), Style(fg: theme.faint, bg: bg))
        }
    }
}
