import Foundation

/// Imports a third-party TYP into the library.
///
/// Two ways in: a scan of the Garmin folders on every mounted volume, and a typed path.
/// Either way the file is copied into the library; the original is never written to.
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
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("import")),
                    Hint(key: "type", label: t("filter")),
                    Hint(key: Glyph.tab, label: t("type a path")),
                    Hint(key: "esc", label: t("back"))]
        case .path:
            var hints = [Hint(key: Glyph.enter, label: t("import"))]
            if FilePicker.isAvailable { hints.append(Hint(key: "^O", label: t("browse"))) }
            hints.append(Hint(key: Glyph.tab, label: t("back to the list")))
            hints.append(Hint(key: "esc", label: t("back")))
            return hints
        }
    }

    private enum Mode { case found, path }

    private let onImported: () -> Void
    private var mode: Mode = .found
    private var candidates: [TypCandidate] = []
    private var scanning = true
    private var started = false
    private var list = ListState()
    private var query = ""
    private var path = ""
    private var message: String?
    private var messageIsError = false

    /// The rights question while it is on screen, and the file it is asked about. Asked
    /// once per import, not once per session: the claim is about one file's licence.
    private var asking: Dialog?
    private var pending: URL?
    /// What the questions say about the file, so the second one can repeat it.
    private var pendingDetail: [(label: String, value: String)] = []

    /// The question asked first for a bare TYP: what importing it alone leaves out.
    private var warning: Dialog?

    /// The recover offer after an import from a `.img`, and the pair it is about. Offered
    /// rather than performed: reading a whole map takes minutes and needs the OSM data.
    private var offering: Dialog?
    private var recoverable: (img: URL, typ: URL)?

    /// What the library already holds, by fingerprint and by product, so an entry can say
    /// that it has been taken before.
    private var held = TypLibrary.Held()

    init(onImported: @escaping () -> Void) {
        self.onImported = onImported
    }

    private var visible: [TypCandidate] {
        guard !query.isEmpty else { return candidates }
        let q = query.lowercased()
        return candidates.filter {
            $0.name.lowercased().contains(q)
                || $0.location.lowercased().contains(q)
                || "\($0.familyID)".contains(q)
        }
    }

    // MARK: Scanning

    func tick(_ ctx: AppContext) {
        guard !started else { return }
        started = true
        refreshHeld()

        // Off the render loop: this reaches into the Garmin folder of every mounted
        // volume, which takes seconds on removable media.
        let output = ctx.settings.settings.outputURL
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let found = TypLibrary.discover(excluding: output)
            // Handed over on the main actor: `publish` writes an array the render loop
            // reads on the next frame.
            await MainActor.run { self.publish(found) }
        }
    }

    private func publish(_ found: [TypCandidate]) {
        candidates = found
        scanning = false
    }

    private func refreshHeld() {
        held = TypLibrary.held()
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if var open = offering {
            switch open.handle(key) {
            case .confirmed:
                offering = nil
                guard let pair = recoverable else { return .none }
                recoverable = nil
                return .push(RecoverScreen(img: pair.img, typ: pair.typ))
            case .cancelled:
                offering = nil
                recoverable = nil
            case .none:
                offering = open
            }
            return .none
        }
        // Modal like the rights question, and asked before it: confirming moves on to it,
        // cancelling drops the import.
        if var open = warning {
            switch open.handle(key) {
            case .confirmed:
                warning = nil
                askAboutRights()
            case .cancelled:
                warning = nil
                pending = nil
                say(t("nothing was imported"), error: false)
            case .none:
                warning = open
            }
            return .none
        }
        // The dialog is modal: while it is up nothing behind it receives a key, so the
        // list cannot move under a question about the file it was on.
        if var open = asking {
            switch open.handle(key) {
            case .confirmed:
                asking = nil
                if let url = pending { take(url, ctx: ctx) }
                pending = nil
            case .cancelled:
                asking = nil
                pending = nil
                say(t("nothing was imported"), error: false)
            case .none:
                asking = open
            }
            return .none
        }

        switch key {
        case .tab, .backTab:
            mode = mode == .found ? .path : .found
            message = nil
        case .ctrl("c"):
            return .quit
        default:
            switch mode {
            case .found: handleFound(key, ctx: ctx)
            case .path: return handlePath(key, ctx: ctx)
            }
        }
        return route
    }

    /// Set when a key handler wants to leave, so the mode handlers need not thread a
    /// `Route` back out.
    private var route: Route = .none

    private func handleFound(_ key: KeyEvent, ctx: AppContext) {
        route = .none
        let shown = visible
        switch key {
        case .up: list.move(-1, count: shown.count)
        case .down: list.move(1, count: shown.count)
        case .pageUp: list.move(-10, count: shown.count, wrap: false)
        case .pageDown: list.move(10, count: shown.count, wrap: false)
        case .home: list.jump(to: 0, count: shown.count)
        case .end: list.jump(to: shown.count - 1, count: shown.count)
        case .backspace:
            if !query.isEmpty { query.removeLast(); list.selected = 0 }
        case .char(let c):
            query.append(c)
            list.selected = 0
        case .enter:
            guard let candidate = shown[safe: list.selected] else { return }
            ask(about: candidate.url, candidate: candidate)
        case .esc:
            if !query.isEmpty { query = ""; list.selected = 0; return }
            route = .pop
        default: break
        }
    }

    private func handlePath(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch key {
        case .ctrl("o"):
            // The system's own file dialog, for paths too long to type.
            if let chosen = FilePicker.choose(.file(extensions: ["typ", "img"]),
                                              startingAt: startingPoint(),
                                              prompt: t("import a TYP")) {
                path = chosen.path
                message = nil
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

    private func say(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    /// Puts the rights question up, with the file's name, size and origin written under it.
    private func ask(about url: URL, candidate: TypCandidate?) {
        var detail: [(label: String, value: String)] = [
            (t("file"), url.lastPathComponent),
            (t("from"), Paths.display(url.deletingLastPathComponent())),
        ]
        if let candidate {
            detail.append((t("size"), Fmt.bytes(candidate.size)))
            detail.append((t("family"), "\(candidate.familyID) · \(candidate.productID)"))
        }
        // Already held byte for byte: another identical copy adds nothing, so the existing
        // entry is named instead.
        if let name = held.exact[TypLibrary.fingerprint(ofTypAt: url)] {
            say(t("already in the library as %@ · in styles: c copies it, o brings back the"
                + " original", name), error: false)
            return
        }

        pending = url
        pendingDetail = detail

        // A bare TYP is a different import and gets its own question first: what is lost
        // by taking the file alone is a choice rather than a confirmation.
        if !ImgContainer.isImg(url) {
            warning = Dialog(
                title: t("Only the drawing"),
                body: [t("A TYP file holds the drawing: colours, patterns, icons. Which"
                       + " code stands for a forest or a trunk road is not in it — that is"
                       + " read out of the map itself."),
                       t("So recovering the style is not available for a TYP on its own."
                       + " If you have the .img this file came from, import that instead:"
                       + " kmap takes the TYP out of it and can work the codes out too.")],
                detail: detail,
                confirm: t("import anyway"),
                cancel: t("cancel"),
                tone: .plain)
            return
        }
        askAboutRights()
    }

    /// The rights question, the same for every import that gets this far.
    private func askAboutRights() {
        asking = Dialog(
            title: t("Important"),
            body: [t("I confirm that the copyright in the files being imported is mine, or"
                   + " that their author has given me permission, or that they are open"
                   + " source and copying and editing them is allowed."),
                   t("The copy stays on this machine. kmap does not publish it and does not"
                   + " send it anywhere; what is done with it afterwards is yours to answer"
                   + " for.")],
            detail: pendingDetail,
            confirm: t("I confirm"),
            cancel: t("cancel"))
    }

    /// Copies a TYP into the library, lifting it out of a `.img` and decompiling it where
    /// there is one to decompile.
    private func take(_ url: URL, ctx: AppContext) {
        do {
            let result = try TypLibrary.take(at: url)
            // What was taken, from where, and that the rights were confirmed, recorded
            // beside the copy.
            TypLibrary.recordImport(from: url, to: result.url,
                                    fingerprint: result.fingerprint,
                                    note: "rights confirmed by the user")
            message = describe(result, from: url)
            messageIsError = false
            path = ""
            refreshHeld()
            ctx.styles.rescanStyles()
            onImported()
            // A TYP lifted out of a map is half the style; which code stands for what can
            // be read back out of the map itself.
            if ImgContainer.isImg(url) {
                recoverable = (img: url, typ: result.url)
                offering = Dialog(
                    title: t("Recover the style?"),
                    body: [t("A TYP records how type codes are drawn. The map records the"
                           + " other half: which code stands for a forest or a trunk road."
                           + " kmap can read that out of the map — builds with this style"
                           + " then look the same as the original."),
                           t("The whole map is read, which takes a few minutes.")],
                    detail: [(t("map"), url.lastPathComponent)],
                    confirm: t("recover"),
                    cancel: t("not now"),
                    tone: .plain)
            }
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    /// One line describing the import: where the copy landed, and how completely the
    /// source was decoded, including the count of elements the decoder refused.
    private func describe(_ result: TypLibrary.Imported, from url: URL) -> String {
        var parts: [String] = []
        if ImgContainer.isImg(url) {
            parts.append(t("lifted out of %@", url.lastPathComponent))
        }
        if result.decompiled {
            parts.append(tn("decompiled %d element(s)", result.elements))
            if result.refused > 0 {
                parts.append(tn("%d not fully decoded — marked in the file", result.refused))
            }
        }
        parts.append("→ \(Paths.display(result.url))")
        return parts.joined(separator: " · ")
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        let intro = t("kmap works with a copy in its own folder and does not touch the "
                    + "original again. The style keeps working even if the source file "
                    + "was on a removable drive.")
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        switch mode {
        case .path: drawPathEntry(into: s, rect: rect, y: &y, theme: theme)
        case .found: drawFound(into: s, rect: rect, y: &y, theme: theme, frame: ctx.frame)
        }

        if let message, y < rect.maxY {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }

        // Drawn last: a dialog covers everything else while it is up.
        asking?.render(into: s, rect: rect, theme: theme)
        warning?.render(into: s, rect: rect, theme: theme)
        offering?.render(into: s, rect: rect, theme: theme)
    }

    private func drawPathEntry(into s: Surface, rect: Rect, y: inout Int, theme: Theme) {
        s.text(rect.x, y, t("Path to a .typ or a Garmin .img:"),
               Style(fg: theme.text, bg: theme.appBg))
        y += 1
        let end = s.text(rect.x, y, path, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        y += 2
        for chunk in wrapText(t("A .img has its TYP lifted out here — there is no need to "
                              + "unpack it first. `~` is expanded."), width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
    }

    private func drawFound(into s: Surface, rect: Rect, y: inout Int, theme: Theme, frame: Int) {
        let shown = visible

        let x = s.text(rect.x, y, t("filter") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(x, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        if scanning {
            s.textRight(rect.maxX, y, t("%@ searching your drives…",
                                        String(Widgets.spinner(frame))),
                        Style(fg: theme.dim, bg: theme.appBg))
        } else {
            s.textRight(rect.maxX, y, t("%d of %d", shown.count, candidates.count),
                        Style(fg: theme.faint, bg: theme.appBg))
        }
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        guard !shown.isEmpty else {
            s.text(rect.x, y, scanning
                    ? t("looking…")
                    : (candidates.isEmpty
                        ? t("nothing found — press ⇥ and type a path instead")
                        : t("nothing matches \"%@\"", query)),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
            return
        }

        let listHeight = max(1, rect.maxY - y - 2)
        list.clamp(count: shown.count, visible: listHeight)
        let listTop = y

        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let candidate = shown[safe: index] else { break }
            draw(candidate, into: s, rect: rect, y: y, theme: theme,
                 selected: index == list.selected)
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)
    }

    private func draw(_ candidate: TypCandidate, into s: Surface, rect: Rect, y: Int,
                      theme: Theme, selected: Bool) {
        // Only an exact fingerprint match is dimmed: several distinct TYPs share one family
        // id, and holding one of them says nothing about the others.
        let holding = TypLibrary.holding(of: candidate, in: held)
        let trailing: String
        var alreadyHeld = false
        switch holding {
        case .exact:
            trailing = t("in library")
            alreadyHeld = true
        case .family: trailing = t("family %d already here", candidate.familyID)
        case .none: trailing = Fmt.bytes(candidate.size)
        }

        Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                    text: candidate.name + "  ·  " + t("family %d", candidate.familyID)
                        + "  ·  " + candidate.location,
                    trailing: trailing,
                    theme: theme,
                    selected: selected,
                    dimmed: alreadyHeld,
                    leading: candidate.isEmbedded ? "img " : "typ ",
                    leadingColor: candidate.isEmbedded ? theme.accentDim : theme.faint)
    }
}
