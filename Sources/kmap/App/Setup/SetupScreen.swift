import Foundation

/// What a first build asks for, and getting it: install what is missing, say how far
/// along it is, then start the build the person asked for.
@MainActor
final class SetupScreen: Screen {
    var page: Page { Page(t("setup"), subject: subject, keys: keys) }

    private var subject: String {
        switch stage {
        case .asking: return t("%d to install", missing.count)
        case .installing: return progress.tool
        case .failed: return t("did not finish")
        case .ready: return t("ready")
        }
    }

    private var keys: [Hint] {
        switch stage {
        case .asking: return asking?.footerHints ?? []
        case .installing: return [Hint(key: "^C", label: t("stop"))]
        case .failed: return [Hint(key: Glyph.enter, label: t("try again")), Hint(key: "esc", label: t("back"))]
        case .ready: return [Hint(key: Glyph.enter, label: t("build"))]
        }
    }

    private enum Stage {
        case asking
        case installing
        case failed(String)
        case ready
    }

    private static let logLines = 400
    private static let detailColumn = 20

    /// In install order: mkgmap is patched with a javac, so Java comes first.
    private let missing: [ToolStatus]
    private let whenReady: (AppContext) -> Route

    private var stage: Stage = .asking
    private var asking: Dialog?
    private let log = Log(limit: SetupScreen.logLines)
    private let progress = InstallProgress()
    private var runner = ProcessRunner()
    private var task: Task<Void, Never>?
    private var installer: ToolInstaller?
    private var wantedForTesting: [ToolStatus]?
    private var started = false
    /// Which start the running task belongs to: a stopped one must not set the stage.
    private var run = 0

    init(missing: [ToolStatus], whenReady: @escaping (AppContext) -> Route) {
        self.missing = missing
        self.whenReady = whenReady
        asking = Dialog(
            title: t("kmap needs a couple of things first"),
            body: [SetupScreen.explanation],
            detail: missing.map { (label: $0.name, value: $0.note ?? t("kmap can install this")) },
            confirm: t("install"),
            cancel: t("not now"),
            tone: .plain
        )
    }

    private static var explanation: String {
        t(
            "A map is compiled by mkgmap, which is a Java program, so both have to be on"
                + " this machine. kmap fetches them into %@ and changes nothing else.",
            Paths.display(Paths.root)
        )
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch stage {
        case .asking:
            guard let answer = asking.take(key) else { return .pop }
            switch answer {
            case .confirmed:
                stage = .installing
                start(ctx)
            case .cancelled: return .pop
            case .none: break
            }
            return .none

        case .installing:
            if key == .ctrl("c") { stop() }
            return .none

        case .failed:
            switch key {
            case .enter:
                stage = .installing
                start(ctx)
            case .esc, .ctrl("c"): return .pop
            default: break
            }
            return .none

        case .ready:
            switch key {
            case .enter: return whenReady(ctx)
            case .esc: return .pop
            default: return .none
            }
        }
    }

    /// The task as well as the process: a download stops only through its task.
    private func stop() {
        task?.cancel()
        task = nil
        runner.cancel()
        log.warn(t("stopped"))
        stage = .failed(t("stopped"))
    }

    private func start(_ ctx: AppContext) {
        started = true
        run += 1
        let id = run
        runner = ProcessRunner()
        let runner = self.runner
        let toolchain = ctx.toolchain
        let log = self.log
        let progress = self.progress
        let install =
            installer ?? { id, log, runner, progress in
                try await toolchain.install(id, log: log, runner: runner, progress: progress)
            }
        let known = wantedForTesting
        task = Task { [weak self] in
            // Re-read, off the main actor: the probe spawns processes. An earlier
            // attempt may have installed some of it.
            var wanted = known ?? []
            if known == nil {
                wanted = await Task.detached { Toolchain.missingRequirements(in: toolchain.status()) }.value
            }
            var failure: String?
            for (index, tool) in wanted.enumerated() {
                progress.begin(tool.name, index: index + 1, of: wanted.count)
                log.step(t("installing %@", tool.name))
                do {
                    try await install(tool.id, log, runner, progress)
                    log.ok(t("%@ installed", tool.name))
                } catch {
                    if Task.isCancelled { return }
                    failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    log.error(failure ?? "")
                    break
                }
            }
            progress.finish()
            guard let self else { return }
            await MainActor.run {
                guard self.run == id else { return }
                ctx.refreshTools(force: true)
                if let failure {
                    self.stage = .failed(failure)
                } else if ctx.toolchain.canBuild {
                    self.stage = .ready
                } else {
                    self.stage = .failed(t("something is still missing"))
                }
            }
        }
    }

    // MARK: For the tests

    /// Stands in for the install and for the probe, so neither the network nor this
    /// machine decides the test.
    func useForTesting(installer: @escaping ToolInstaller, wanted: [ToolStatus]) {
        self.installer = installer
        wantedForTesting = wanted
    }

    var isStoppedForTesting: Bool {
        if case .failed(let why) = stage { return why == t("stopped") }
        return false
    }

    // MARK: Drawing

    func tick(_ ctx: AppContext) {}

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let faint = Style(fg: theme.faint, bg: theme.appBg)
        var y = s.paragraph(SetupScreen.explanation, x: rect.x, y: rect.y, width: rect.w, style: faint)
        y += 1

        for tool in missing {
            guard y < rect.maxY else { break }
            let ready = ctx.tools.first { $0.id == tool.id }?.isReady ?? false
            s.text(
                rect.x,
                y,
                "\(ready ? Glyph.check : Glyph.dot) \(tool.name)",
                Style(fg: ready ? theme.ok : theme.dim, bg: theme.appBg)
            )
            s.text(
                rect.x + Self.detailColumn,
                y,
                truncate(tool.detail, to: max(0, rect.w - Self.detailColumn)),
                faint
            )
            y += 1
        }
        y += 1

        if case .installing = stage {
            drawProgress(into: s, rect: rect, y: &y, theme: theme, frame: ctx.frame)
        }
        if case .failed(let why) = stage, y < rect.maxY {
            y = s.paragraph(
                why,
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.danger, bg: theme.appBg),
                maxY: rect.maxY
            )
            y += 1
        }
        if case .ready = stage, y < rect.maxY {
            s.text(rect.x, y, t("Everything is in place — press ⏎ to build."), Style(fg: theme.ok, bg: theme.appBg))
            y += 2
        }

        if y < rect.maxY - 1 {
            s.sectionRule(
                rect,
                y,
                t("output"),
                labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
            )
            y += 1
            Widgets.logPane(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w, h: max(0, rect.maxY - y)),
                lines: log.snapshot().filter { $0.severity > .debug },
                theme: theme
            )
        }

        asking?.render(into: s, rect: rect, theme: theme)
    }

    private func drawProgress(into s: Surface, rect: Rect, y: inout Int, theme: Theme, frame: Int) {
        guard y + 2 < rect.maxY else { return }
        let position = progress.position
        var heading = "\(Widgets.spinner(frame)) \(progress.tool)"
        if position.of > 1 { heading += "  \(position.index)/\(position.of)" }
        s.text(rect.x, y, heading, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 1
        InstallProgressRow.draw(s, x: rect.x, y: y, width: rect.w, progress: progress, theme: theme)
        y += 3
    }
}
