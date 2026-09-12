import Foundation

/// Shows what kmap needs, what it has, and installs the parts it can.
///
/// Several installs run at once, each drawing its own progress in its row. One that
/// fetches what another is fetching waits for it instead: the patch pulls mkgmap in on
/// its own, and two of those into one folder would be a mess.
final class ToolchainScreen: Screen {
    var page: Page { Page(t("toolchain"), keys: keys) }

    private var keys: [Hint] {
        var hints = [Hint(key: "↑↓", label: t("move")),
                     Hint(key: Glyph.enter, label: t("install")),
                     Hint(key: "u", label: t("update")),
                     Hint(key: "a", label: t("install all missing")),
                     Hint(key: "x", label: t("remove")),
                     Hint(key: "r", label: t("re-check"))]
        hints.append(isBusy ? Hint(key: "^C", label: t("stop"))
                            : Hint(key: "esc", label: t("back")))
        return hints
    }

    /// One install in flight: what its row draws, and what stops it.
    final class Running {
        let progress = InstallProgress()
        let runner = ProcessRunner()
        var task: Task<Void, Never>?

        /// The process a step may be running, and the task, through which cancellation
        /// reaches a download.
        func stop() {
            task?.cancel()
            runner.cancel()
        }
    }

    private var list = ListState()
    private var running: [String: Running] = [:]
    /// Waiting for an install that overlaps theirs, in the order they were asked for.
    private var queued: [String] = []
    private var installer: ToolInstaller?
    private var log = Log(limit: 500)
    private var message: String?
    private var refreshed = false
    /// The tool whose root install has been asked about and not yet answered.
    private var awaitingRoot: String?

    private var isBusy: Bool { !running.isEmpty || !queued.isEmpty }

    /// Read from the shared snapshot - probing here would spawn a process per frame.
    private func tools(_ ctx: AppContext) -> [ToolStatus] { ctx.tools }

    func tick(_ ctx: AppContext) {
        if !refreshed {
            refreshed = true
            ctx.refreshTools(force: true)
        } else {
            ctx.refreshTools()
        }
        // The data packs are the only things here that go out of date while installed,
        // so the screen asks about them whatever the build's own schedule says.
        ctx.refreshPackNews()
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let tools = tools(ctx)
        switch key.command {
        case .up, .char("k"): awaitingRoot = nil; list.move(-1, count: tools.count)
        case .down, .char("j"): awaitingRoot = nil; list.move(1, count: tools.count)
        case .char("r"):
            ctx.refreshTools(force: true)
            ctx.refreshPackNews(force: true)
            message = t("re-checking…")
        case .char("u"):
            guard let tool = tools[safe: list.selected] else { return .none }
            update(tool, ctx)
        case .esc:
            guard !isBusy else {
                message = t("still installing: ^C stops everything")
                return .none
            }
            return .pop
        case .ctrl("c"):
            guard isBusy else { return .quit }
            stopEverything()
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
            installAllMissing(tools, ctx)
        case .char("x"):
            guard let tool = tools[safe: list.selected] else { return .none }
            remove(tool, ctx)
        default: break
        }
        return .none
    }

    /// What pressing `u` would do. Only the data packs go out of date while installed;
    /// the rest of this list is programs, whose versions kmap does not chase.
    enum UpdateAction: Equatable {
        /// Fetch the published pack over the one that is here.
        case fetch
        /// Not installed at all, so this is an install like any other.
        case install
        /// Nothing to do, and what to say about it.
        case nothing(String)
    }

    func updateAction(for tool: ToolStatus, _ ctx: AppContext) -> UpdateAction {
        guard DataPack.named(tool.id) != nil else {
            return .nothing(t("%@ is not something kmap updates", tool.name))
        }
        guard tool.isReady else { return .install }
        guard ctx.packNews[tool.id] != nil else {
            return .nothing(ctx.packsChecked ? t("%@ is already the published one", tool.name)
                                             : t("still checking…"))
        }
        return .fetch
    }

    /// Fetches a pack again by hand: the install path already replaces and stamps it, and
    /// this is how a pack that is merely out of date can be asked for at all.
    private func update(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !isInstalling(tool.id) else {
            message = t("%@ is still installing", tool.name)
            return
        }
        switch updateAction(for: tool, ctx) {
        case .nothing(let said): message = said
        case .install: install(tool, ctx)
        case .fetch: start(tool, ctx, force: true)
        }
    }

    private func remove(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !isInstalling(tool.id) else {
            message = t("%@ is still installing", tool.name)
            return
        }
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

    // MARK: Starting

    private func install(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !isInstalling(tool.id) else {
            message = queued.contains(tool.id) ? waitingNote(for: tool.id, ctx)
                                               : t("%@ is still installing", tool.name)
            return
        }
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

    /// Everything missing that a build needs, at once; what has to be installed as root
    /// is left for its own Enter, since the question is asked one tool at a time.
    private func installAllMissing(_ tools: [ToolStatus], _ ctx: AppContext) {
        let wanted = tools.filter {
            !$0.isFinished && $0.installable && !$0.isOptional && !isInstalling($0.id)
        }
        guard !wanted.isEmpty else {
            message = t("nothing left to install")
            return
        }
        var asRoot: [String] = []
        for tool in wanted {
            if ctx.toolchain.rootInstallCommand(for: tool.id) != nil {
                asRoot.append(tool.name)
            } else {
                start(tool, ctx)
            }
        }
        if !asRoot.isEmpty {
            message = t("needs root, press Enter on its row: %@", asRoot.joined(separator: ", "))
        }
    }

    private func start(_ tool: ToolStatus, _ ctx: AppContext, force: Bool = false) {
        guard force || !tool.isFinished else {
            message = t("%@ is already installed", tool.name)
            return
        }
        guard tool.installable else {
            message = tool.note ?? t("%@ has to be installed by hand", tool.name)
            return
        }
        message = nil
        if blockers(of: tool.id, ahead: queued).isEmpty {
            launch(tool, ctx)
        } else {
            queued.append(tool.id)
            message = waitingNote(for: tool.id, ctx)
        }
    }

    private func launch(_ tool: ToolStatus, _ ctx: AppContext) {
        let job = Running()
        running[tool.id] = job
        let log = self.log
        let toolchain = ctx.toolchain
        let install = installer ?? { id, log, runner, progress in
            try await toolchain.install(id, log: log, runner: runner, progress: progress)
        }

        log.step(t("installing %@", tool.name))
        job.progress.begin(tool.name)
        job.task = Task { [weak self] in
            do {
                try await install(tool.id, log, job.runner, job.progress)
                log.ok(t("%@ installed", tool.name))
            } catch {
                // A stopped install is said once, by the key that stopped it.
                if !Task.isCancelled { log.error(error.localizedDescription) }
            }
            guard let self else { return }
            await MainActor.run { self.finished(tool.id, ctx) }
        }
    }

    private func finished(_ id: String, _ ctx: AppContext) {
        running.removeValue(forKey: id)
        ctx.refreshTools(force: true)
        ctx.refreshPackNews(force: true)
        startQueued(ctx)
    }

    /// Launches every queued install nothing overlaps any more, in the order asked.
    private func startQueued(_ ctx: AppContext) {
        var launched = true
        while launched {
            launched = false
            for (at, id) in queued.enumerated()
            where blockers(of: id, ahead: Array(queued.prefix(at))).isEmpty {
                queued.remove(at: at)
                if let tool = ctx.tools.first(where: { $0.id == id }) { launch(tool, ctx) }
                launched = true
                break
            }
        }
    }

    private func stopEverything() {
        for job in running.values { job.stop() }
        queued.removeAll()
        log.warn(t("stopped"))
        message = nil
    }

    private func isInstalling(_ id: String) -> Bool {
        running[id] != nil || queued.contains(id)
    }

    /// The running and earlier-queued installs `id` overlaps with.
    private func blockers(of id: String, ahead: [String]) -> [String] {
        (running.keys.sorted() + ahead).filter { Toolchain.overlap(id, $0) }
    }

    private func waitingNote(for id: String, _ ctx: AppContext) -> String {
        let names = blockers(of: id, ahead: queued.prefix { $0 != id }).map { blocker in
            ctx.tools.first { $0.id == blocker }?.name ?? blocker
        }
        return t("waiting for %@", names.joined(separator: ", "))
    }

    // MARK: For the tests

    var messageForTesting: String? { message }
    var runningForTesting: [String] { running.keys.sorted() }
    var queuedForTesting: [String] { queued }
    func progressForTesting(_ id: String) -> InstallProgress? { running[id]?.progress }

    /// Stands in for `Toolchain.install`, so a key can be pressed without fetching a
    /// gigabyte.
    func useForTesting(installer: @escaping ToolInstaller) { self.installer = installer }

    // MARK: Drawing

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
            let selected = i == list.selected
            let bg = selected ? theme.selectionBg : theme.appBg
            let job = running[tool.id]
            let waiting = queued.contains(tool.id)

            if selected {
                s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 3), Style(fg: theme.text, bg: bg))
                s.vline(rect.x, y, 3, Glyph.bar, Style(fg: theme.accent, bg: bg))
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
            s.text(rect.x + 22, y, tool.detail, Style(fg: theme.faint, bg: bg),
                   limit: max(0, rect.w - 24))

            // An install in flight takes the row's other two lines for itself.
            if let job {
                InstallProgressRow.draw(s, x: rect.x + 4, y: y + 1, width: rect.w - 6,
                                        progress: job.progress, theme: theme, bg: bg)
                y += 3
                continue
            }

            let statusText = waiting ? waitingNote(for: tool.id, ctx)
                : (tool.isReady ? (tool.version ?? t("ready")) : t("not installed"))
            let after = s.text(rect.x + 4, y + 1, truncate(statusText, to: rect.w - 6),
                               Style(fg: tool.isReady ? theme.dim : theme.warn, bg: bg))
            // A pack the mirror has moved on from, said where the note would go.
            if !waiting, let news = ctx.packNews[tool.id] {
                let room = rect.maxX - after - 4
                let said = t("newer one published %@ — press u", news.describedShortly)
                if room > 8 {
                    s.text(after + 1, y + 1, truncate("\(Glyph.dot) \(said)", to: room),
                           Style(fg: theme.accent, bg: bg))
                }
            } else if tool.isReady, let note = tool.note {
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
