import Foundation

/// Imports a third-party TYP into the library, from a scan of the Garmin folders on every
/// mounted volume or from a typed path. The original is never written to.
final class ImportTypScreen: Screen {
    var page: Page {
        Page(t("import a TYP"), subject: mode == .found ? nil : t("by path"), keys: keys)
    }

    private var keys: [Hint] {
        if let offering { return offering.footerHints }
        if let warning { return warning.footerHints }
        if let asking { return asking.footerHints }
        switch mode {
        case .found:
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("import")),
                Hint(key: "type", label: t("filter")),
                Hint(key: Glyph.tab, label: t("type a path")),
                Hint(key: "esc", label: t("back"))
            ]
        case .path:
            var hints = [Hint(key: Glyph.enter, label: t("import"))]
            if FilePicker.isAvailable { hints.append(Hint(key: "^O", label: t("browse"))) }
            hints.append(Hint(key: Glyph.tab, label: t("back to the list")))
            hints.append(Hint(key: "esc", label: t("back")))
            return hints
        }
    }

    enum Mode { case found, path }

    /// What the questions say about a file, so the second can repeat it.
    typealias Pending = (url: URL, detail: [(label: String, value: String)])

    let onImported: () -> Void
    var mode: Mode = .found
    var candidates: [TypCandidate] = []
    var scanning = true
    private var started = false
    var filter = TypedFilter()
    var path = ""
    var notice = Notice()

    /// For a bare TYP: what importing it alone leaves out. Asked before the rights.
    var warning: Question<Pending>?
    /// The rights question, once per import.
    var asking: Question<Pending>?
    /// After an import from a `.img`: recover the style from it? Offered, not done,
    /// since reading a map takes minutes.
    var offering: Question<(img: URL, typ: URL)>?

    /// What the library already holds, by fingerprint and by product.
    var held = TypLibrary.Held()

    init(onImported: @escaping () -> Void) {
        self.onImported = onImported
    }

    var visible: [TypCandidate] {
        guard !filter.isEmpty else { return candidates }
        return candidates.filter { filter.matches([$0.name, $0.location, "\($0.familyID)"]) }
    }

    /// The scan reaches into every mounted volume, so it runs off the render loop.
    func tick(_ ctx: AppContext) {
        guard !started else { return }
        started = true
        refreshHeld()
        let output = ctx.settings.settings.outputURL
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let found = TypLibrary.discover(excluding: output)
            await MainActor.run {
                self.candidates = found
                self.scanning = false
            }
        }
    }

    func refreshHeld() {
        held = TypLibrary.held()
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let (answer, pair) = offering.take(key) {
            return answer == .confirmed ? .push(RecoverScreen(img: pair.img, typ: pair.typ)) : .none
        }
        if let (answer, pending) = warning.take(key) {
            switch answer {
            case .confirmed: askAboutRights(pending)
            case .cancelled: notice.say(t("nothing was imported"))
            case .none: break
            }
            return .none
        }
        if let (answer, pending) = asking.take(key) {
            switch answer {
            case .confirmed: take(pending.url, ctx: ctx)
            case .cancelled: notice.say(t("nothing was imported"))
            case .none: break
            }
            return .none
        }

        switch key {
        case .tab, .backTab:
            mode = mode == .found ? .path : .found
            notice.clear()
            return .none
        case .ctrl("c"):
            return .quit
        default:
            switch mode {
            case .found: return handleFound(key)
            case .path: return handlePath(key)
            }
        }
    }

    private func handleFound(_ key: KeyEvent) -> Route {
        let shown = visible
        if filter.take(key, count: shown.count) { return .none }
        switch key {
        case .enter:
            guard let candidate = shown[safe: filter.list.selected] else { return .none }
            ask(about: candidate.url, candidate: candidate)
        case .esc:
            if filter.clear() { return .none }
            return .pop
        default: break
        }
        return .none
    }

    private func handlePath(_ key: KeyEvent) -> Route {
        switch key {
        case .ctrl("o"):
            if let chosen = FilePicker.choose(
                .file(extensions: ["typ", "img"]),
                startingAt: startingPoint(),
                prompt: t("import a TYP")
            ) {
                path = chosen.path
                notice.clear()
            }
        case .backspace: if !path.isEmpty { path.removeLast() }
        case .char(let c): path.append(c)
        case .paste(let text): path += text.replacingOccurrences(of: "\n", with: "")
        case .enter:
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .none }
            ask(about: Paths.expand(trimmed), candidate: nil)
        case .esc: return .pop
        default: break
        }
        return .none
    }

    /// Where the file dialog opens: the path already typed, when it exists.
    private func startingPoint() -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let url = Paths.expand(trimmed)
        return FileTools.exists(url) ? url : nil
    }
}
