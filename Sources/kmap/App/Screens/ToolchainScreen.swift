import Foundation

/// Shows what kmap needs, what it has, and installs the parts it can.
final class ToolchainScreen: Screen {
    var page: Page { Page(t("toolchain"), keys: keys) }

    private var keys: [Hint] {
        if installing != nil {
            return [Hint(key: "^C", label: t("stop"))]
        }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("install")),
                Hint(key: "a", label: t("install all missing")),
                Hint(key: "x", label: t("remove")),
                Hint(key: "r", label: t("re-check")),
                Hint(key: "esc", label: t("back"))]
    }

    private var list = ListState()
    private var installing: String?
    private var log = Log(limit: 500)
    private var runner = ProcessRunner()
    private var message: String?
    private var refreshed = false

    /// Read from the shared snapshot — probing here would spawn a process per frame.
    private func tools(_ ctx: AppContext) -> [ToolStatus] { ctx.tools }

    func tick(_ ctx: AppContext) {
        if !refreshed {
            refreshed = true
            ctx.refreshTools(force: true)
        } else {
            ctx.refreshTools()
        }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if installing != nil {
            if key == .ctrl("c") {
                runner.cancel()
                log.warn(t("stopped"))
                installing = nil
            }
            return .none
        }

        let tools = tools(ctx)
        switch key.command {
        case .up, .char("k"): awaitingRoot = nil; list.move(-1, count: tools.count)
        case .down, .char("j"): awaitingRoot = nil; list.move(1, count: tools.count)
        case .char("r"): ctx.refreshTools(force: true); message = t("re-checking…")
        case .esc: return .pop
        case .ctrl("c"): return .quit
        case .enter:
            guard let tool = tools[safe: list.selected] else { return .none }
            install(tool, ctx)
        case .char("y"):
            // Only ever answers the question below; anywhere else it is an ordinary key
            // this screen has nothing to do with.
            guard let id = awaitingRoot, let tool = tools.first(where: { $0.id == id }) else {
                return .none
            }
            awaitingRoot = nil
            start(tool, ctx)
        case .char("a"):
            guard let tool = tools.first(where: { !$0.isReady && $0.installable && !$0.isOptional }) else {
                message = t("nothing left to install")
                return .none
            }
            install(tool, ctx)
        case .char("x"):
            guard let tool = tools[safe: list.selected] else { return .none }
            remove(tool, ctx)
        default: break
        }
        return .none
    }

    private func remove(_ tool: ToolStatus, _ ctx: AppContext) {
        guard tool.removable else {
            message = t("%@ cannot be removed", tool.name)
            return
        }
        do {
            try ctx.toolchain.remove(tool.id, log: log)
            message = t("%@ removed", tool.name)
            ctx.refreshTools(force: true)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// The tool whose root install has been asked about and not yet answered.
    private var awaitingRoot: String?

    private func install(_ tool: ToolStatus, _ ctx: AppContext) {
        // A package manager writes across the whole machine, and on a box with passwordless
        // sudo nothing would stop to say so. Asked once per tool, and the answer is not
        // remembered: the next install asks again.
        // Only `y` ever starts a root install: a second Enter re-poses the question
        // rather than answering it, or the consent is one repeated keystroke deep.
        if let command = ctx.toolchain.rootInstallCommand(for: tool.id) {
            awaitingRoot = tool.id
            message = t("this installs a system package as root:  %@   —  press y to go ahead",
                        command)
            return
        }
        awaitingRoot = nil
        start(tool, ctx)
    }

    private func start(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !tool.isFinished else {
            message = t("%@ is already installed", tool.name)
            return
        }
        guard tool.installable else {
            message = tool.note ?? t("%@ has to be installed by hand", tool.name)
            return
        }

        message = nil
        installing = tool.id
        runner = ProcessRunner()
        let runner = self.runner
        let toolchain = ctx.toolchain
        let log = self.log

        log.step(t("installing %@", tool.name))
        Task { [weak self] in
            do {
                try await toolchain.install(tool.id, log: log, runner: runner)
                log.ok(t("%@ installed", tool.name))
            } catch {
                log.error(error.localizedDescription)
            }
            guard let self else { return }
            await MainActor.run {
                self.installing = nil
                ctx.refreshTools(force: true)
            }
        }
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        // Wrapped, not clipped: the path in the middle makes this line longer than a
        // narrow window, and a sentence cut at the edge reads as a mistake.
        let intro = t("A map needs Java and mkgmap. Everything kmap installs"
                    + " lives under %@.", Paths.display(Paths.root))
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        let tools = tools(ctx)
        if tools.isEmpty {
            s.text(rect.x, y, t("checking %@", String(Widgets.spinner(ctx.frame))),
                   Style(fg: theme.dim, bg: theme.appBg))
            return
        }
        list.clamp(count: tools.count, visible: max(1, tools.count * 3))

        for (i, tool) in tools.enumerated() {
            guard y + 2 < rect.maxY else { break }
            let selected = i == list.selected && installing == nil
            let bg = selected ? theme.selectionBg : theme.appBg

            if selected {
                s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 3), Style(fg: theme.text, bg: bg))
                s.vline(rect.x, y, 3, Glyph.bar, Style(fg: theme.accent, bg: bg))
            }

            let (marker, tone): (String, Color) = {
                if installing == tool.id { return (String(Widgets.spinner(ctx.frame)), theme.accent) }
                switch tool.state {
                case .ready: return (String(Glyph.check), theme.ok)
                case .missing: return (String(Glyph.cross), theme.warn)
                case .broken: return ("!", theme.danger)
                }
            }()

            s.text(rect.x + 2, y, marker, Style(fg: tone, bg: bg))
            s.text(rect.x + 4, y, tool.name, Style(fg: theme.strong, bg: bg, bold: true))
            s.text(rect.x + 22, y, tool.detail, Style(fg: theme.faint, bg: bg),
                   limit: max(0, rect.w - 24))

            let statusText = installing == tool.id ? t("installing…")
                : (tool.isReady ? (tool.version ?? t("ready")) : t("not installed"))
            let after = s.text(rect.x + 4, y + 1, truncate(statusText, to: rect.w - 6),
                               Style(fg: tool.isReady ? theme.dim : theme.warn, bg: bg))
            // A ready tool shows its path below, so what it cannot do goes here instead.
            if tool.isReady, let note = tool.note {
                let room = rect.maxX - after - 4
                if room > 8 {
                    s.text(after + 1, y + 1, truncate("\(Glyph.dot) \(note)", to: room),
                           Style(fg: theme.warn, bg: bg))
                }
            }

            if let path = tool.path {
                s.text(rect.x + 4, y + 2, truncate(path, to: rect.w - 6),
                       Style(fg: theme.faint, bg: bg))
            } else if let note = tool.note {
                s.text(rect.x + 4, y + 2, truncate(note, to: rect.w - 6),
                       Style(fg: theme.faint, bg: bg))
            }
            y += 3
        }

        if let message {
            guard y < rect.maxY else { return }
            s.text(rect.x + 2, y, message, Style(fg: theme.warn, bg: theme.appBg))
            y += 1
        }

        let lines = log.snapshot()
        guard !lines.isEmpty, y + 2 < rect.maxY else { return }
        y += 1
        s.sectionRule(rect, y, t("log"),
                      labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        Widgets.logPane(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: max(0, rect.maxY - y)),
                        lines: lines, theme: theme)
    }
}
