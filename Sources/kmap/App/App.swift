import Foundation

/// Top-level controller: owns the terminal, the navigation stack, and the render loop.
/// Main-actor isolated, so screen state is only ever touched from one thread.
@MainActor
final class App {
    /// The most keys one frame takes: a held arrow repeats faster than frames are drawn,
    /// and one key a frame leaves the list moving after the key is up. A long paste still
    /// redraws in between.
    static let keysPerFrame = 32
    /// Below this the screen is not drawn at all.
    static let leastSize = (w: 20, h: 6)
    /// The margin between the chrome and a screen's content, in cells.
    static let contentInset = 2

    let terminal = Terminal()
    let surface = Surface()
    let ctx = AppContext()
    private var stack: [Screen] = []
    private var lastFrame = ""
    private var lastSize = (w: 0, h: 0)
    private var running = true

    func run() async {
        Paths.bootstrap()
        // The language must be resolved before the first frame is drawn.
        L10n.bootstrap(ctx.settings)
        terminal.start()
        defer { terminal.stop() }

        stack.append(MainMenuScreen())
        ctx.loadIndexIfNeeded()
        ctx.renewPatchIfStale()

        while running, let active = stack.last {
            takeKeys(for: active)
            guard let current = stack.last else { break }

            terminal.setMouseTracking(current.wantsMouse)
            current.tick(ctx)

            let (w, h) = terminal.size()
            surface.resize(w, h)
            render(current, width: w, height: h)
            ctx.frame += 1

            if terminal.inputHasEnded { exitWithoutATerminal() }
            // The wait for a key paces the loop; yield so background work can run.
            await Task.yield()
        }
    }

    /// One key, and whatever else is already decoded, up to a frame's worth. A screen
    /// change ends the run so the eye sees it.
    private func takeKeys(for active: Screen) {
        guard let key = terminal.readKey() else { return }
        apply(active.handle(key, ctx: ctx))
        var taken = 1
        while taken < App.keysPerFrame, stack.last === active,
            terminal.hasBufferedKey, let more = terminal.readKey()
        {
            apply(active.handle(more, ctx: ctx))
            taken += 1
        }
    }

    /// With no input left the loop would spin, so the interface exits instead.
    private func exitWithoutATerminal() -> Never {
        running = false
        terminal.stop()
        CLILog.error(
            "kmap's interface needs a terminal to read keys from. Run"
                + " it from one, or use the command line — `kmap --help`"
                + " lists what it can do without a screen."
        )
        ChildProcess.leave()
        exit(1)
    }

    private func apply(_ route: Route) {
        switch route {
        case .none: break
        case .push(let screen): stack.append(screen)
        // The main menu stays: only q or ^C leaves kmap.
        case .pop: if stack.count > 1 { stack.removeLast() }
        case .popToRoot: if stack.count > 1 { stack.removeSubrange(1...) }
        case .replace(let screen): if !stack.isEmpty { stack[stack.count - 1] = screen }
        case .quit: running = false
        }
    }

    private func render(_ screen: Screen, width w: Int, height h: Int) {
        guard w > App.leastSize.w, h > App.leastSize.h else { return }
        // After a file dialog the console is not where it was left, and the difference
        // against the last frame would draw nothing.
        if terminal.takeRepaintRequest() { lastFrame = "" }
        // A resize rewraps the old frame, so it is dropped and the screen cleared.
        if (w, h) != lastSize {
            lastSize = (w, h)
            lastFrame = ""
            terminal.clearScreen()
        }
        surface.clear(ctx.theme.base)

        ctx.refreshLoad()
        drawHeader(screen, width: w)
        let inset = App.contentInset
        let content = Rect(x: inset, y: inset, w: w - 2 * inset, h: h - 2 * inset)
        screen.render(into: surface, rect: content, ctx: ctx)
        drawFooter(screen, width: w, y: h - 1)
        screen.renderOverlay(into: surface, rect: content, ctx: ctx)

        let frame = surface.compose()
        if frame != lastFrame {
            terminal.output(frame)
            lastFrame = frame
        }
    }
}
