import Foundation

/// Top-level controller: owns the terminal, the navigation stack, and the render loop.
/// Main-actor isolated, so that screen state is only ever touched from one thread.
@MainActor
final class App {
    private let terminal = Terminal()
    private let surface = Surface()
    private let ctx = AppContext()
    private var stack: [Screen] = []
    private var lastFrame = ""
    private var running = true

    func run() async {
        Paths.bootstrap()
        // The language must be resolved before the first frame is drawn.
        L10n.bootstrap(ctx.settings)
        terminal.start()
        defer { terminal.stop() }

        stack.append(MainMenuScreen())
        ctx.loadIndexIfNeeded()

        while running, let active = stack.last {
            if let key = terminal.readKey() {
                apply(active.handle(key, ctx: ctx))
                // Whatever else is already decoded goes with it, up to a frame's worth:
                // a held arrow repeats faster than frames are drawn, and taking one key
                // a frame leaves the list moving after the key is long up. Nothing is
                // waited for, and a screen change ends the run so the eye sees it.
                var taken = 1
                while taken < App.keysPerFrame, stack.last === active,
                      terminal.hasBufferedKey, let more = terminal.readKey() {
                    apply(active.handle(more, ctx: ctx))
                    taken += 1
                }
            }
            guard let current = stack.last else { break }

            terminal.setMouseTracking(current.wantsMouse)
            current.tick(ctx)

            let (w, h) = terminal.size()
            surface.resize(w, h)
            render(current, width: w, height: h)

            ctx.frame += 1

            // With no input left the loop would spin, so the interface exits instead.
            if terminal.inputHasEnded {
                running = false
                terminal.stop()
                CLILog.error("kmap's interface needs a terminal to read keys from. Run"
                             + " it from one, or use the command line — `kmap --help`"
                             + " lists what it can do without a screen.")
                exit(1)
            }

            // The wait for a key paces the loop; yield so background work can run.
            await Task.yield()
        }
    }

    private func apply(_ route: Route) {
        switch route {
        case .none: break
        case .push(let screen): stack.append(screen)
        case .pop: if stack.count > 1 { stack.removeLast() } else { running = false }
        case .popToRoot: if stack.count > 1 { stack.removeSubrange(1...) }
        case .replace(let screen): if !stack.isEmpty { stack[stack.count - 1] = screen }
        case .quit: running = false
        }
    }

    /// The most keys one frame will take, so a long paste still redraws in between.
    private static let keysPerFrame = 32

    private var lastSize = (w: 0, h: 0)

    private func render(_ screen: Screen, width w: Int, height h: Int) {
        guard w > 20, h > 6 else { return }
        // After a file dialog the console is not where it was left, and the difference
        // against the last frame would draw nothing.
        if terminal.takeRepaintRequest() { lastFrame = "" }
        // A resize rewraps the old frame, so the cached frame is dropped and the screen
        // cleared before an unconditional redraw.
        if (w, h) != lastSize {
            lastSize = (w, h)
            lastFrame = ""
            terminal.output("\u{1B}[2J")
        }
        let theme = ctx.theme
        surface.clear(theme.base)

        ctx.refreshLoad()
        drawHeader(screen, width: w)
        let content = Rect(x: 2, y: 2, w: w - 4, h: h - 4)
        screen.render(into: surface, rect: content, ctx: ctx)
        drawFooter(screen, width: w, y: h - 1)
        screen.renderOverlay(into: surface, rect: content, ctx: ctx)

        let frame = surface.compose()
        if frame != lastFrame {
            terminal.output(frame)
            lastFrame = frame
        }
    }

    private func drawHeader(_ screen: Screen, width w: Int) {
        let theme = ctx.theme
        let bar = Style(fg: theme.headerFg, bg: theme.headerBg)
        surface.fill(Rect(x: 0, y: 0, w: w, h: 1), bar)

        var x = surface.text(2, 0, "kmap", bar.with(fg: theme.accent, bold: true))
        x = surface.text(x + 1, 0, String(Glyph.dot), bar.with(fg: theme.faint))
        surface.text(x + 1, 0, screen.title, bar.with(fg: theme.headerFg))

        let load = ctx.load
        let pieces = Widgets.headerRight(width: w, titleEnds: x + screen.title.count,
                                         clock: Fmt.clock(), load: load)
        for (i, piece) in pieces.enumerated() {
            // The clock comes first and is dim; memory turns to the warning colour above
            // 90% used.
            let style: Style
            if i == 0 {
                style = bar.with(fg: theme.dim)
            } else if piece.text.hasSuffix(t("GB")), load.memoryFraction > 0.9 {
                style = bar.with(fg: theme.warn, bold: true)
            } else {
                style = bar.with(fg: theme.faint)
            }
            surface.textRight(piece.endsAt, 0, piece.text, style)
        }
    }

    private func drawFooter(_ screen: Screen, width w: Int, y: Int) {
        let theme = ctx.theme
        let bar = Style(fg: theme.footerFg, bg: theme.footerBg)
        surface.fill(Rect(x: 0, y: y, w: w, h: 1), bar)
        // The version sits at the far end; hints stop short of it.
        let version = Version.full
        let room = w - 2 - version.count - 2
        var x = 2
        for hint in screen.footerHints {
            if x + hint.key.count + hint.label.count + 4 >= room { break }
            x = surface.text(x, y, hint.key, bar.with(fg: theme.accent, bold: true))
            x = surface.text(x + 1, y, hint.label, bar)
            x += 3
        }
        if room > 0 { surface.textRight(w - 2, y, version, bar.with(fg: theme.dim)) }
    }
}
