import Foundation

/// Takes a drawing from another style: first the source, then the type within it, both
/// shown at true size.
///
/// Nothing is scaled. A donor drawn for a different size is offered with its size stated
/// and used as it is.
final class IconDonorScreen: Screen {

    var page: Page {
        let subject: String
        switch stage {
        case .style: subject = t("from which style")
        case .type: subject = donorName
        case .file: subject = t("from a file")
        }
        return Page(t("borrow a drawing"), subject: subject, keys: keys)
    }

    private var keys: [Hint] {
        switch stage {
        case .style:
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("open")),
                    Hint(key: "esc", label: t("back"))]
        case .file:
            var hints = [Hint(key: Glyph.enter, label: loaded == nil ? t("load") : t("use this one"))]
            if FilePicker.isAvailable { hints.append(Hint(key: "^O", label: t("browse"))) }
            hints.append(Hint(key: Glyph.tab, label: t("back to the styles")))
            hints.append(Hint(key: "esc", label: t("back")))
            return hints
        case .type:
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("use this one")),
                    Hint(key: "type", label: t("filter")),
                    Hint(key: "esc", label: t("back to the list"))]
        }
    }

    private enum Stage { case style, type, file }

    private let kind: MapElementKind
    private let target: TypSection?
    private let onPick: (XpmBlock) -> Void

    private var stage: Stage = .style
    private var styles: [MapStyle] = []
    private var donor: TypSource?
    private var donorName = ""
    private var donorSections: [TypSection] = []
    private var list = ListState()
    private var query = ""
    private var message: String?

    /// The path being typed, and what came of loading it.
    private var path = ""
    private var loaded: IconImport.Result?

    /// - Parameter target: the section being replaced, for showing what is there now.
    init(kind: MapElementKind, target: TypSection?, onPick: @escaping (XpmBlock) -> Void) {
        self.kind = kind
        self.target = target
        self.onPick = onPick
    }

    func tick(_ ctx: AppContext) {
        guard styles.isEmpty else { return }
        // Only styles whose TYP is source text: a compiled one has nothing to offer until
        // it has been imported, which decompiles it.
        styles = ctx.styles.styles().list.filter { style in
            guard let url = style.typURL else { return false }
            return url.pathExtension.lowercased() == "txt"
        }
    }

    private var visibleSections: [TypSection] {
        guard !query.isEmpty else { return donorSections }
        let q = query.lowercased()
        return donorSections.filter {
            $0.hex.contains(q)
                || $0.englishLabel?.lowercased().contains(q) == true
                || $0.russianLabel?.lowercased().contains(q) == true
        }
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch stage {
        case .style: return handleStyle(key)
        case .type: return handleType(key)
        case .file: return handleFile(key)
        }
    }

    /// The source rows: a file on disk, then one row per readable style.
    private var sourceRowCount: Int { styles.count + 1 }

    private func handleStyle(_ key: KeyEvent) -> Route {
        switch key {
        case .tab, .backTab:
            stage = .file
            message = nil
        case .up: list.move(-1, count: sourceRowCount)
        case .down: list.move(1, count: sourceRowCount)
        case .enter:
            guard list.selected > 0 else {
                stage = .file
                message = nil
                return .none
            }
            guard let style = styles[safe: list.selected - 1] else { return .none }
            open(style)
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func open(_ style: MapStyle) {
        guard let url = style.typURL, let source = TypSource.read(url) else {
            message = t("%@ could not be read", style.name)
            return
        }
        donor = source
        donorName = style.name
        // Only sections carrying a picture; one with colours alone has nothing to lend.
        donorSections = source.sections(kind).filter { $0.picture != nil }
        stage = .type
        list = ListState()
        query = ""
        message = donorSections.isEmpty
            ? t("%1$@ has no %2$@ to lend", style.name, kind.plural) : nil
    }

    private func handleType(_ key: KeyEvent) -> Route {
        let shown = visibleSections
        switch key {
        case .up: list.move(-1, count: shown.count)
        case .down: list.move(1, count: shown.count)
        case .pageUp: list.move(-10, count: shown.count, wrap: false)
        case .pageDown: list.move(10, count: shown.count, wrap: false)
        case .backspace:
            if !query.isEmpty { query.removeLast(); list.selected = 0 }
        case .char(let c):
            query.append(c)
            list.selected = 0
        case .enter:
            guard let section = shown[safe: list.selected],
                  let picture = section.picture else { return .none }
            onPick(picture)
            return .pop
        case .esc:
            if !query.isEmpty { query = ""; list.selected = 0; return .none }
            stage = .style
            list = ListState()
            return .none
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// A picture on disk, read at the size of the drawing it would replace. Loading and
    /// using it are separate keystrokes, so the result is drawn before it is accepted.
    private func handleFile(_ key: KeyEvent) -> Route {
        switch key {
        case .ctrl("o"):
            // Every extension the importer can read.
            if let chosen = FilePicker.choose(
                .file(extensions: ["png", "jpg", "jpeg", "svg", "gif", "tif", "tiff", "bmp"]),
                startingAt: nil, prompt: t("take an icon from a file")) {
                path = chosen.path
                loaded = nil
                message = nil
            }
        case .tab, .backTab:
            stage = .style
            message = nil
        case .backspace:
            if !path.isEmpty { path.removeLast(); loaded = nil }
        case .char(let c):
            path.append(c)
            loaded = nil
        case .paste(let text):
            path += text.replacingOccurrences(of: "\n", with: "")
            loaded = nil
        case .enter:
            if let loaded {
                onPick(loaded.block)
                return .pop
            }
            load()
        case .esc:
            return .pop
        case .ctrl("c"):
            return .quit
        default: break
        }
        return .none
    }

    private func load() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // The size of what is being replaced, so a drop-in replacement stays a drop-in.
        let size = target?.picture?.width ?? 20
        do {
            loaded = try IconImport.load(Paths.expand(trimmed), size: size)
            message = nil
        } catch {
            loaded = nil
            message = error.localizedDescription
        }
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        switch stage {
        case .style: renderStyles(s, rect: rect, theme: ctx.theme)
        case .type: renderTypes(s, rect: rect, theme: ctx.theme)
        case .file: renderFile(s, rect: rect, theme: ctx.theme)
        }
    }

    private func renderFile(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        let size = target?.picture?.width ?? 20
        for chunk in wrapText(
            t("A picture is read at %@ — the size of the drawing "
            + "it would replace. PNG, JPEG, TIFF, GIF and BMP work, and SVG "
            + "where the system can draw it. `~` is expanded.", "\(size)×\(size)"),
            width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        s.text(rect.x, y, t("Path:"), Style(fg: theme.text, bg: theme.appBg))
        y += 1
        let end = s.text(rect.x, y, path, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        y += 2

        guard let loaded else {
            if let message, y < rect.maxY {
                s.text(rect.x, y, truncate(message, to: rect.w),
                       Style(fg: theme.danger, bg: theme.appBg))
            }
            return
        }

        // What is there now, beside what it would become, at the same scale.
        let rows = max(1, rect.maxY - y - 3)
        let room = pair(rect, current: target?.picture, rows: rows)
        s.text(rect.x, y, t("now"), Style(fg: theme.dim, bg: theme.appBg))
        let rightColumn = room.rightColumn
        s.text(rightColumn, y, t("would become"), Style(fg: theme.dim, bg: theme.appBg))
        y += 1

        var used = 1
        if let current = target?.picture {
            used = Widgets.picture(s, x: rect.x, y: y, current, background: theme.appBg,
                                   maxColumns: room.columns, maxRows: rows)
        } else {
            s.text(rect.x, y, t("nothing"), Style(fg: theme.faint, bg: theme.appBg))
        }
        used = max(used, Widgets.picture(s, x: rightColumn, y: y, loaded.block,
                                         background: theme.appBg,
                                         maxColumns: room.columns, maxRows: rows))
        y += used + 1

        guard y < rect.maxY else { return }
        s.text(rightColumn, y, "\(loaded.block.width)×\(loaded.block.height), "
               + tn("%d colour(s)", loaded.paletteSize),
               Style(fg: theme.faint, bg: theme.appBg))
        y += 1

        // What the import had to give up, shown before the drawing is accepted.
        for warning in loaded.warnings {
            guard y < rect.maxY else { return }
            for chunk in wrapText(warning, width: rect.w) {
                guard y < rect.maxY else { return }
                s.text(rect.x, y, chunk, Style(fg: theme.warn, bg: theme.appBg))
                y += 1
            }
        }
        if loaded.warnings.isEmpty, y < rect.maxY {
            s.text(rect.x, y, t("read at its own size, nothing scaled and no colour lost"),
                   Style(fg: theme.ok, bg: theme.appBg))
        }
    }

    private func renderStyles(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        for chunk in wrapText(
            t("A drawing comes from a picture on disk, or from another "
            + "style whose TYP is readable — a compiled one has nothing to "
            + "offer until it is imported, which decompiles it."),
            width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        list.clamp(count: sourceRowCount, visible: max(1, rect.maxY - y - 1))

        Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: 1), y: y,
                    text: t("A picture on disk — PNG, JPEG, SVG…"),
                    trailing: t("read at %d px", target?.picture?.width ?? 20),
                    theme: theme, selected: list.selected == 0,
                    leading: "＋ ", leadingColor: theme.accent)
        y += 1

        if styles.isEmpty, y < rect.maxY {
            s.text(rect.x, y, "  " + t("no other readable style — import one to borrow from it"),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        for (index, style) in styles.enumerated() {
            guard y < rect.maxY - 1 else { break }
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: 1), y: y,
                        text: style.name, trailing: t("family %d", style.familyID),
                        theme: theme, selected: index + 1 == list.selected)
            y += 1
        }
        if let message, y < rect.maxY {
            s.text(rect.x, rect.maxY - 1, message, Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    private func renderTypes(_ s: Surface, rect: Rect, theme: Theme) {
        let shown = visibleSections
        var y = rect.y

        let fx = s.text(rect.x, y, t("filter") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(fx, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        s.textRight(rect.maxX, y, t("%d of %d", shown.count, donorSections.count),
                    Style(fg: theme.faint, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        guard !shown.isEmpty else {
            s.text(rect.x, y, message ?? t("nothing matches \"%@\"", query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        // The comparison takes the bottom half, between 6 and 14 rows.
        let compareHeight = min(14, max(6, rect.h / 2))
        let listHeight = max(1, rect.maxY - y - compareHeight - 1)
        list.clamp(count: shown.count, visible: listHeight)
        let listTop = y

        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let section = shown[safe: index] else { break }
            let picture = section.picture
            let size = picture.map { "\($0.width)×\($0.height)" } ?? ""
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                        text: "\(section.hex)  \(section.englishLabel ?? section.russianLabel ?? "")",
                        trailing: size, theme: theme, selected: index == list.selected)
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)

        guard let section = shown[safe: list.selected] else { return }
        compare(section, into: s,
                rect: Rect(x: rect.x, y: listTop + listHeight + 1, w: rect.w,
                           h: rect.maxY - listTop - listHeight - 1),
                theme: theme)
    }

    /// Room for two drawings side by side: how wide each may be, and the column the second
    /// starts at. Both are reduced by the same rule, so they compare at one scale.
    private func pair(_ rect: Rect, current: XpmBlock?, rows: Int)
        -> (columns: Int, rightColumn: Int) {
        let columns = max(2, (rect.w - 6) / 2)
        let width = current.map {
            Widgets.pictureFit($0, maxColumns: columns, maxRows: rows).columns
        } ?? 0
        return (columns, rect.x + max(24, width + 6))
    }

    private func compare(_ donorSection: TypSection, into s: Surface, rect: Rect,
                         theme: Theme) {
        guard rect.h > 2 else { return }
        s.hline(rect.x, rect.y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        var y = rect.y + 1

        let current = target?.picture
        let incoming = donorSection.picture

        let rows = max(1, rect.maxY - y - 2)
        let room = pair(rect, current: current, rows: rows)
        s.text(rect.x, y, t("now"), Style(fg: theme.dim, bg: theme.appBg))
        let rightColumn = room.rightColumn
        s.text(rightColumn, y, t("would become"), Style(fg: theme.dim, bg: theme.appBg))
        y += 1

        var used = 0
        if let current {
            used = Widgets.picture(s, x: rect.x, y: y, current, background: theme.appBg,
                                   maxColumns: room.columns, maxRows: rows)
        } else {
            s.text(rect.x, y, t("nothing"), Style(fg: theme.faint, bg: theme.appBg))
            used = 1
        }
        if let incoming {
            used = max(used, Widgets.picture(s, x: rightColumn, y: y, incoming,
                                             background: theme.appBg,
                                             maxColumns: room.columns, maxRows: rows))
        }
        y += used + 1

        guard y < rect.maxY else { return }
        func facts(_ block: XpmBlock?) -> String {
            guard let block else { return t("no drawing") }
            return "\(block.width)×\(block.height), " + tn("%d colour(s)", block.declaredColours)
        }
        let here = facts(current)
        let there = facts(incoming)
        s.text(rect.x, y, here, Style(fg: theme.faint, bg: theme.appBg))
        s.text(rightColumn, y, there, Style(fg: theme.faint, bg: theme.appBg))
        y += 1

        // A size mismatch is reported, not acted on: nothing here scales a drawing.
        if let current, let incoming,
           current.width != incoming.width || current.height != incoming.height, y < rect.maxY {
            s.text(rect.x, y,
                   t("different size — it will be used as it is, not scaled to fit"),
                   Style(fg: theme.warn, bg: theme.appBg))
        }
    }
}
