import Foundation

/// One style: its identity, its coverage, and a way into each part of it.
///
/// Coverage compares the type codes the rule set emits against the sections the TYP styles.
/// Neither file records the other, and a code the TYP has no section for is drawn by the
/// device however it chooses, with nothing to announce it.
final class StyleDetailScreen: Screen {

    var page: Page { Page(document.style.name, keys: keys) }

    private var keys: [Hint] {
        var hints = [Hint(key: "↑↓", label: t("move")), Hint(key: Glyph.enter, label: t("open"))]
        if !document.isEditable, document.isReadable {
            hints.append(Hint(key: "^F", label: t("editable copy")))
        }
        if !isDefault { hints.append(Hint(key: "d", label: t("make default"))) }
        if recoverableMap != nil { hints.append(Hint(key: "r", label: t("recover from its map"))) }
        hints.append(Hint(key: "esc", label: t("back")))
        return hints
    }

    /// The map this TYP was extracted from, or nil once that path stops resolving. Recovery
    /// reads it to learn which code the map used for what.
    private let recoverableMap: URL?

    private enum Row {
        case kind(MapElementKind)
        case drawOrder
    }

    private let document: StyleDocument
    private var list = ListState()
    private var message: String?
    private var isDefault = false

    init(style: MapStyle) {
        self.document = StyleDocument.load(style)
        if case .importedTYP(let typ) = style.origin {
            recoverableMap = TypLibrary.importedSource(of: typ)
        } else {
            recoverableMap = nil
        }
    }

    private var rows: [Row] {
        guard document.isReadable else { return [] }
        return MapElementKind.allCases.map(Row.kind) + [.drawOrder]
    }

    func tick(_ ctx: AppContext) {
        isDefault = ctx.settings.settings.defaultStyleID == document.style.id
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let rows = self.rows
        switch key.command {
        case .up: list.move(-1, count: rows.count)
        case .down: list.move(1, count: rows.count)
        case .enter:
            switch rows[safe: list.selected] {
            case .kind(let kind):
                return .push(TypeBrowserScreen(document: document, kind: kind))
            case .drawOrder:
                return .push(DrawOrderScreen(document: document))
            case nil:
                return .none
            }
        case .char("d"):
            ctx.settings.update { $0.defaultStyleID = document.style.id }
            message = t("%@ is now the default", document.style.name)
        case .ctrl("f"):
            return adopt(ctx)
        case .char("r"):
            guard let img = recoverableMap, let typ = document.sourceURL else { return .none }
            return .push(RecoverScreen(img: img, typ: typ))
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        y = drawIdentity(into: s, rect: rect, y: y, theme: theme)
        y += 1

        guard document.isReadable else {
            y = drawUnreadable(into: s, rect: rect, y: y, theme: theme)
            drawMessage(into: s, rect: rect, y: y, theme: theme)
            return
        }

        if !document.isEditable {
            for chunk in wrapText(readOnlyReason, width: rect.w) {
                guard y < rect.maxY else { break }
                s.text(rect.x, y, chunk, Style(fg: theme.warn, bg: theme.appBg))
                y += 1
            }
            y += 1
        }

        y = drawCoverage(into: s, rect: rect, y: y, theme: theme)
        y += 1

        s.sectionRule(rect, y, t("edit"), labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        for (index, row) in rows.enumerated() {
            guard y < rect.maxY - 1 else { break }
            draw(row, into: s, rect: rect, y: y, theme: theme, selected: index == list.selected)
            y += 1
        }
        drawMessage(into: s, rect: rect, y: y + 1, theme: theme)
    }

    /// Puts an editable copy of this style into the TYP library and opens it. A built-in
    /// style's working copy is rewritten from the embedded asset whenever a build finds the
    /// two differ, so an edit in place would be silently undone.
    private func adopt(_ ctx: AppContext) -> Route {
        guard let text = document.source?.text, !document.isEditable else { return .none }
        do {
            let landed = try TypLibrary.adopt(source: text, named: document.style.name)
            ctx.styles.rescanStyles()
            guard let style = StyleCatalog.libraryStyle(at: landed) else {
                message = t("copied to %@", Paths.display(landed))
                return .none
            }
            return .replace(StyleDetailScreen(style: style))
        } catch {
            message = error.localizedDescription
            return .none
        }
    }

    // MARK: Parts

    private func drawIdentity(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        let style = document.style

        var x = s.text(rect.x, y, style.name, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        if isDefault {
            s.text(x + 2, y, t("default"), Style(fg: theme.ok, bg: theme.appBg))
        }
        y += 1

        for chunk in wrapText(t(style.summary), width: rect.w).prefix(2) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        // mkgmap rewrites the embedded TYP's family id to match the build's; a mismatch
        // makes the device ignore the TYP outright.
        var facts = [t("family %d", document.familyID),
                     t("product %d", document.productID)]
        if let codePage = document.codePage {
            facts.append(t("code page") + " \(codePage)")
        }
        facts.append(kindLabel)
        x = s.text(rect.x, y, facts.joined(separator: "  ·  "),
                   Style(fg: theme.dim, bg: theme.appBg))
        y += 1

        if let url = document.sourceURL {
            s.text(rect.x, y, truncate(Paths.display(url), to: rect.w),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        if let img = recoverableMap {
            s.text(rect.x, y, truncate(t("from map %@", img.lastPathComponent), to: rect.w),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        return y
    }

    private var kindLabel: String {
        switch document.availability {
        case .source: return document.isEditable ? t("editable source") : t("read-only source")
        case .binary: return t("compiled TYP")
        case .none: return t("no TYP")
        }
    }

    /// Why this style cannot be edited in place.
    private var readOnlyReason: String {
        document.style.origin == .builtin || document.sourceURL == nil
            ? t("This is kmap's own TYP, and its working copy is rewritten from the shipped "
              + "one whenever a build finds the two differ — an edit here would be undone "
              + "without a word. Press ^F for an editable copy in your TYP library.")
            : t("This file is outside kmap's TYP library, which is the only place kmap writes "
              + "a TYP. Press ^F for an editable copy.")
    }

    /// Draws the explanation for a style whose TYP cannot be opened. Returns the next free
    /// row.
    private func drawUnreadable(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        let explanation: String
        switch document.availability {
        case .binary:
            explanation = t("This TYP is compiled. Its identity reads fine, but its sections "
                + "cannot be opened yet: mkgmap compiles source into a TYP and offers no way "
                + "back, so decoding one is work kmap has to do itself. Until then the file "
                + "can still be built with — it is simply not editable here.")
        case .none:
            explanation = t("This style ships no TYP. The device draws every type its own way, "
                + "so there is nothing here to edit.")
        case .source:
            explanation = ""
        }
        for chunk in wrapText(explanation, width: rect.w) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, chunk, Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }
        return y
    }

    /// Draws, per element kind, the split between codes the rule set emits and codes the TYP
    /// styles. Returns the next free row.
    private func drawCoverage(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        s.sectionRule(rect, y, t("coverage"), labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        guard document.rules != nil else {
            s.text(rect.x, y, t("the rule set has not been unpacked yet — run a build once"),
                   Style(fg: theme.warn, bg: theme.appBg))
            return y + 1
        }

        for kind in MapElementKind.allCases {
            guard y < rect.maxY else { break }
            let coverage = document.coverage(kind)
            var x = s.text(rect.x, y, kind.plural.padding(toLength: 12, withPad: " ",
                                                          startingAt: 0),
                           Style(fg: theme.text, bg: theme.appBg))
            x = s.text(x, y, t("%d of %d styled", coverage.both, coverage.emitted),
                       Style(fg: theme.text, bg: theme.appBg))

            if !coverage.unstyled.isEmpty {
                x = s.text(x + 2, y, tn("%d fall back to the device", coverage.unstyled.count),
                           Style(fg: theme.warn, bg: theme.appBg))
            }
            // Not a fault: the TYP declares these as deliberately left to the device.
            if !coverage.deliberate.isEmpty {
                x = s.text(x + 2, y, tn("%d left to it on purpose", coverage.deliberate.count),
                           Style(fg: theme.faint, bg: theme.appBg))
            }
            if !coverage.unused.isEmpty {
                s.textRight(rect.maxX, y,
                            tn("%d styled but never emitted", coverage.unused.count),
                            Style(fg: theme.faint, bg: theme.appBg))
            }
            y += 1
        }

        // A polygon absent from [_drawOrder] is never drawn, with nothing said about it.
        let missing = document.polygonsNeverDrawn
        if !missing.isEmpty, y < rect.maxY {
            let list = missing.prefix(8).map(TypeMeaning.hex).joined(separator: " ")
            s.text(rect.x, y, t("polygons missing from the draw order, never drawn: %@", list),
                   Style(fg: theme.danger, bg: theme.appBg))
            y += 1
        }
        return y
    }

    private func draw(_ row: Row, into s: Surface, rect: Rect, y: Int, theme: Theme,
                      selected: Bool) {
        let text: String
        let trailing: String
        switch row {
        case .kind(let kind):
            text = label(for: kind)
            let coverage = document.coverage(kind)
            trailing = tn("%d section(s)", coverage.styled)
        case .drawOrder:
            text = t("Draw order — which polygon is painted over which")
            trailing = tn("%d entries", document.source?.drawOrder.count ?? 0)
        }
        Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: 1), y: y,
                    text: text, trailing: trailing, theme: theme, selected: selected)
    }

    private func label(for kind: MapElementKind) -> String {
        switch kind {
        case .point: return t("Points — the POI icons")
        case .line: return t("Lines — roads, paths, contours, streams")
        case .polygon: return t("Polygons — landcover fills and hatches")
        }
    }

    private func drawMessage(into s: Surface, rect: Rect, y: Int, theme: Theme) {
        guard let message, y < rect.maxY else { return }
        s.text(rect.x, y, message, Style(fg: theme.ok, bg: theme.appBg))
    }
}
