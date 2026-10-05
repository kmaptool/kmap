import Foundation

/// The maps kmap has produced, in the output folder.
final class LibraryScreen: Screen {
    var page: Page { Page(t("library"), keys: keys) }

    private var keys: [Hint] {
        var hints = [Hint(key: "↑↓", label: t("move"))]
        if Platform.canReveal { hints.append(Hint(key: "o", label: Platform.revealLabel())) }
        hints += [
            Hint(key: "d", label: t("delete")),
            Hint(key: "r", label: t("rescan")),
            Hint(key: "esc", label: t("back"))
        ]
        return hints
    }

    private var files: [URL] = []
    /// Each file's size and date, read once a scan: drawn every frame, asked of the disk once.
    private var details: [URL: (bytes: Int64, modified: String)] = [:]
    private var list = ListState()
    private var message: String?
    private var pendingDelete: URL?
    private var scanned = false

    func tick(_ ctx: AppContext) {
        guard !scanned else { return }
        scanned = true
        rescan(ctx)
    }

    /// Newest first.
    private func rescan(_ ctx: AppContext) {
        let found = BuiltMaps.outputs(under: ctx.settings.settings.outputURL)
            .map { (url: $0, modified: FileTools.modified(of: $0)) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        files = found.map(\.url)
        details = Dictionary(
            found.map { ($0.url, (FileTools.size(of: $0.url), $0.modified.map { Fmt.timestamp($0) } ?? "")) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The name, under its build folder where it has one.
    private func displayName(_ url: URL, root: URL) -> String {
        let parent = url.deletingLastPathComponent()
        guard parent.path != root.path else { return url.lastPathComponent }
        return parent.lastPathComponent + "/" + url.lastPathComponent
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch key.command {
        case .up, .char("k"): list.move(-1, count: files.count); pendingDelete = nil
        case .down, .char("j"): list.move(1, count: files.count); pendingDelete = nil
        case .char("r"): pendingDelete = nil; rescan(ctx); message = tn("%d map(s)", files.count)
        case .char("o"):
            pendingDelete = nil
            guard let file = files[safe: list.selected] else { return .none }
            Reveal.show(file)
            message = t("revealed %@", file.lastPathComponent)
        case .char("d"):
            guard let file = files[safe: list.selected] else { return .none }
            pendingDelete = file
            message = t("delete %@? press ⏎ to confirm, any other key to cancel", file.lastPathComponent)
        case .enter:
            if let target = pendingDelete {
                pendingDelete = nil
                do {
                    try FileTools.remove(target)
                    message = t("deleted")
                } catch {
                    message = t("could not delete: %@", error.localizedDescription)
                }
                rescan(ctx)
            }
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: pendingDelete = nil
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let faint = Style(fg: theme.faint, bg: theme.appBg)
        var y = rect.y
        s.text(rect.x, y, Paths.display(ctx.settings.settings.outputURL), Style(fg: theme.dim, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        if files.isEmpty {
            s.text(rect.x, y + 1, t("no maps built yet"), faint)
            s.paragraph(
                t(
                    "Build one from the main menu. Finished maps land here as .img files; "
                        + "copy one to Garmin/ on the device or its SD card to install it."
                ),
                x: rect.x,
                y: y + 3,
                width: rect.w,
                style: faint
            )
            return
        }

        let listHeight = max(1, rect.maxY - y - 3)
        let listTop = y
        for index in list.window(count: files.count, visible: listHeight) {
            let file = files[index]
            let detail = details[file] ?? (0, "")
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: displayName(file, root: ctx.settings.settings.outputURL),
                trailing: "\(Fmt.bytes(detail.bytes))   \(detail.modified)",
                theme: theme,
                selected: index == list.selected
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: list.offset,
            count: files.count,
            visible: listHeight,
            theme: theme
        )

        if let message {
            s.text(
                rect.x,
                rect.maxY - 1,
                truncate(message, to: rect.w),
                Style(fg: pendingDelete != nil ? theme.danger : theme.dim, bg: theme.appBg)
            )
        }
    }
}
