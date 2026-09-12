import Foundation

/// What a first build asks for, and getting it.
///
/// A map needs Java and mkgmap, and a machine kmap was just installed on has neither.
/// Rather than sending someone to the Toolchain screen to work out which lines matter,
/// this asks once - install what is missing? - and then does it, saying what it is doing
/// and how far along it is, because a silent ten-minute download reads as a hung program.
///
/// Handed a continuation, so the build the person asked for starts by itself once the
/// toolchain is ready.
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
        case .failed: return [Hint(key: Glyph.enter, label: t("try again")),
                              Hint(key: "esc", label: t("back"))]
        case .ready: return [Hint(key: Glyph.enter, label: t("build"))]
        }
    }

    private enum Stage {
        case asking
        case installing
        case failed(String)
        case ready
    }

    /// What is missing, in the order it has to be installed: mkgmap is patched with a
    /// javac, so Java comes first.
    private let missing: [ToolStatus]
    /// What to do once everything is there.
    private let whenReady: (AppContext) -> Route

    private var stage: Stage = .asking
    private var asking: Dialog?
    private let log = Log(limit: 400)
    private let progress = InstallProgress()
    private var runner = ProcessRunner()
    private var task: Task<Void, Never>?
    private var installer: ToolInstaller?
    private var wantedForTesting: [ToolStatus]?
    private var started = false

    init(missing: [ToolStatus], whenReady: @escaping (AppContext) -> Route) {
        self.missing = missing
        self.whenReady = whenReady
        asking = Dialog(
            title: t("kmap needs a couple of things first"),
            body: [SetupScreen.explanation],
            detail: missing.map { (label: $0.name, value: $0.note ?? t("kmap can install this")) },
            confirm: t("install"),
            cancel: t("not now"),
            tone: .plain)
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch stage {
        case .asking:
            guard var open = asking else { return .pop }
            switch open.handle(key) {
            case .confirmed:
                asking = nil
                stage = .installing
                start(ctx)
            case .cancelled:
                return .pop
            case .none:
                asking = open
            }
            return .none

        case .installing:
            if key == .ctrl("c") {
                // The task as well as the process: a download stops only through its task.
                task?.cancel()
                runner.cancel()
                log.warn(t("stopped"))
                stage = .failed(t("stopped"))
            }
            return .none

        case .failed:
            switch key {
            case .enter:
                stage = .installing
                start(ctx)
            case .esc, .ctrl("c"):
                return .pop
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

    // MARK: Doing it

    private func start(_ ctx: AppContext) {
        started = true
        runner = ProcessRunner()
        let runner = self.runner
        let toolchain = ctx.toolchain
        let log = self.log
        let progress = self.progress
        let install = installer ?? { id, log, runner, progress in
            try await toolchain.install(id, log: log, runner: runner, progress: progress)
        }
        // Re-read rather than reusing the list this screen opened with: an earlier attempt
        // may have installed some of it.
        let wanted = wantedForTesting ?? Toolchain.missingRequirements(in: toolchain.status())

        task = Task { [weak self] in
            var failure: String?
            for (index, tool) in wanted.enumerated() {
                progress.begin(tool.name, index: index + 1, of: wanted.count)
                log.step(t("installing %@", tool.name))
                do {
                    try await install(tool.id, log, runner, progress)
                    log.ok(t("%@ installed", tool.name))
                } catch {
                    // Stopped by ^C: the key said so, and the screen is already failed.
                    if Task.isCancelled { return }
                    failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    log.error(failure ?? "")
                    break
                }
            }
            progress.finish()
            guard let self else { return }
            await MainActor.run {
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

    /// Stands in for `Toolchain.install`, so the keys can be pressed without a network,
    /// and for the probe, so what this machine has installed does not decide the test.
    func useForTesting(installer: @escaping ToolInstaller, wanted: [ToolStatus]) {
        self.installer = installer
        wantedForTesting = wanted
    }

    var isStoppedForTesting: Bool {
        if case .failed(let why) = stage { return why == t("stopped") }
        return false
    }

    // MARK: Drawing

    func tick(_ ctx: AppContext) {
        if case .installing = stage, !started { start(ctx) }
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        for chunk in wrapText(SetupScreen.explanation, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        for tool in missing {
            guard y < rect.maxY else { break }
            let ready = ctx.tools.first { $0.id == tool.id }?.isReady ?? false
            let mark = ready ? Glyph.check : Glyph.dot
            let colour = ready ? theme.ok : theme.dim
            s.text(rect.x, y, "\(mark) \(tool.name)", Style(fg: colour, bg: theme.appBg))
            s.text(rect.x + 20, y, truncate(tool.detail, to: max(0, rect.w - 20)),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        if case .installing = stage { drawProgress(into: s, rect: rect, y: &y, theme: theme,
                                                   frame: ctx.frame) }
        if case .failed(let why) = stage, y < rect.maxY {
            for chunk in wrapText(why, width: rect.w) where y < rect.maxY {
                s.text(rect.x, y, chunk, Style(fg: theme.danger, bg: theme.appBg))
                y += 1
            }
            y += 1
        }
        if case .ready = stage, y < rect.maxY {
            s.text(rect.x, y, t("Everything is in place — press ⏎ to build."),
                   Style(fg: theme.ok, bg: theme.appBg))
            y += 2
        }

        // The log below, so a person who wants the detail has it without leaving.
        if y < rect.maxY - 1 {
            s.sectionRule(rect, y, t("output"),
                          labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                          ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
            y += 1
            Widgets.logPane(s, rect: Rect(x: rect.x, y: y, w: rect.w,
                                          h: max(0, rect.maxY - y)),
                            lines: log.snapshot().filter { $0.severity > .debug },
                            theme: theme)
        }

        asking?.render(into: s, rect: rect, theme: theme)
    }

    /// Said once, in the question and again on the screen behind it.
    private static var explanation: String {
        t("A map is compiled by mkgmap, which is a Java program, so both have to be on"
          + " this machine. kmap fetches them into %@ and changes nothing else.",
          Paths.display(Paths.root))
    }

    private func drawProgress(into s: Surface, rect: Rect, y: inout Int, theme: Theme,
                              frame: Int) {
        guard y + 2 < rect.maxY else { return }
        // The spinner turns whatever the stage, so a step with no percentage still moves.
        let position = progress.position
        var heading = "\(Widgets.spinner(frame)) \(progress.tool)"
        if position.of > 1 { heading += "  \(position.index)/\(position.of)" }
        s.text(rect.x, y, heading, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 1

        // The same two lines the toolchain screen draws in a row.
        InstallProgressRow.draw(s, x: rect.x, y: y, width: rect.w, progress: progress,
                                theme: theme)
        y += 3
    }
}
