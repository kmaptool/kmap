import Foundation

/// What kmap needs, what it has, and installing the parts it can. Several installs run at
/// once, each drawing its progress in its row.
final class ToolchainScreen: Screen {
    var page: Page { Page(t("toolchain"), keys: keys) }

    private var keys: [Hint] {
        var hints = [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("install")),
            Hint(key: "u", label: t("update")),
            Hint(key: "a", label: t("install all missing")),
            Hint(key: "x", label: t("remove")),
            Hint(key: "r", label: t("re-check"))
        ]
        hints.append(queue.isBusy ? Hint(key: "^C", label: t("stop")) : Hint(key: "esc", label: t("back")))
        return hints
    }

    static let logLines = 500

    var list = ListState()
    let queue = InstallQueue()
    var installer: ToolInstaller?
    let log = Log(limit: ToolchainScreen.logLines)
    var message: String?
    private var refreshed = false
    /// The tool whose root install is being asked about.
    var awaitingRoot: String?

    /// The shared snapshot: probing here would spawn a process per frame.
    func tools(_ ctx: AppContext) -> [ToolStatus] { ctx.tools }

    func tick(_ ctx: AppContext) {
        if !refreshed {
            refreshed = true
            ctx.refreshTools(force: true)
        } else {
            ctx.refreshTools()
        }
        // The packs go out of date while installed, so the screen asks whatever the
        // build's schedule says.
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
            guard !queue.isBusy else {
                message = t("still installing: ^C stops everything")
                return .none
            }
            return .pop
        case .ctrl("c"):
            guard queue.isBusy else { return .quit }
            stopEverything()
        case .enter:
            guard let tool = tools[safe: list.selected] else { return .none }
            install(tool, ctx)
        case .char("y"):
            // Only ever answers the root question.
            guard let id = awaitingRoot, let tool = tools.first(where: { $0.id == id }) else { return .none }
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

    // MARK: For the tests

    var messageForTesting: String? { message }
    var runningForTesting: [String] { queue.running.keys.sorted() }
    var queuedForTesting: [String] { queue.waiting }
    func progressForTesting(_ id: String) -> InstallProgress? { queue.running[id]?.progress }

    /// Stands in for `Toolchain.install`, so a key can be pressed without fetching a gigabyte.
    func useForTesting(installer: @escaping ToolInstaller) { self.installer = installer }
}
