import Foundation

/// The maps kmap has produced, in the output folder.
final class LibraryScreen: Screen {
    var page: Page { Page(t("library"), keys: keys) }

    private var keys: [Hint] {
        var hints = [Hint(key: "↑↓", label: t("move"))]
        // Omitted where the platform has no file manager to open.
        if Platform.canReveal { hints.append(Hint(key: "o", label: Platform.revealLabel())) }
        hints += [Hint(key: "d", label: t("delete")),
                  Hint(key: "r", label: t("rescan")),
                  Hint(key: "esc", label: t("back"))]
        return hints
    }

    private var files: [URL] = []
    private var list = ListState()
    private var message: String?
    private var pendingDelete: URL?
    private var scanned = false

    func tick(_ ctx: AppContext) {
        if !scanned {
            scanned = true
            rescan(ctx)
        }
    }

    /// Collects `.img` files from the output folder and one level below it, since each
    /// build writes into its own dated folder. Newest first.
    private func rescan(_ ctx: AppContext) {
        let root = ctx.settings.settings.outputURL
        var found = FileTools.contents(of: root, extension: "img")
        for entry in FileTools.contents(of: root) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            found.append(contentsOf: FileTools.contents(of: entry, extension: "img"))
        }
        files = found.sorted {
            (FileTools.modified(of: $0) ?? .distantPast) > (FileTools.modified(of: $1) ?? .distantPast)
        }
    }

    /// The file's path relative to the output folder: its own name, or the containing
    /// build folder and its name.
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
            revealInFinder(file)
            message = t("revealed %@", file.lastPathComponent)
        case .char("d"):
            guard let file = files[safe: list.selected] else { return .none }
            pendingDelete = file
            message = t("delete %@? press ⏎ to confirm, any other key to cancel",
                        file.lastPathComponent)
        case .enter:
            if let target = pendingDelete {
                FileTools.removeIfPresent(target)
                pendingDelete = nil
                rescan(ctx)
                message = t("deleted")
            }
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default:
            pendingDelete = nil
        }
        return .none
    }

    /// Opens the system file manager with this file selected. Does nothing on a platform
    /// with no reveal command.
    private func revealInFinder(_ url: URL) {
        guard let command = Platform.revealCommand(for: url) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try? process.run()
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        s.text(rect.x, y, Paths.display(ctx.settings.settings.outputURL),
               Style(fg: theme.dim, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        if files.isEmpty {
            s.text(rect.x, y + 1, t("no maps built yet"),
                   Style(fg: theme.faint, bg: theme.appBg))
            for (i, chunk) in wrapText(
                t("Build one from the main menu. Finished maps land here as .img files; "
                + "copy one to Garmin/ on the device or its SD card to install it."),
                width: rect.w).enumerated() {
                s.text(rect.x, y + 3 + i, chunk, Style(fg: theme.faint, bg: theme.appBg))
            }
            return
        }

        let listHeight = max(1, rect.maxY - y - 3)
        list.clamp(count: files.count, visible: listHeight)
        let listTop = y
        let visible = min(listHeight, files.count - list.offset)

        for i in 0..<visible {
            let index = list.offset + i
            guard let file = files[safe: index] else { break }
            let modified = FileTools.modified(of: file).map { Fmt.timestamp($0) } ?? ""
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                        y: y,
                        text: displayName(file, root: ctx.settings.settings.outputURL),
                        trailing: "\(Fmt.bytes(FileTools.size(of: file)))   \(modified)",
                        theme: theme,
                        selected: index == list.selected)
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: files.count,
                           visible: listHeight, theme: theme)

        if let message {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
                   Style(fg: pendingDelete != nil ? theme.danger : theme.dim, bg: theme.appBg))
        }
    }
}
