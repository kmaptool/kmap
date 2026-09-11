import Foundation

/// Every type code a style deals in, named in the words that put it there.
///
/// A Garmin type code is a bare number: the meaning lives in the rule set, the drawing
/// lives in the TYP, and neither file refers to the other. This screen shows the two
/// side by side.
final class TypeBrowserScreen: Screen {

    var page: Page {
        Page("\(document.style.name) · \(kind.plural)",
             subject: search.subject, keys: keys)
    }

    private var keys: [Hint] {
        if search.open { return search.hints }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: document.isEditable ? t("change") : t("inspect")),
                Hint(key: "←→", label: t("points/lines/polygons")),
                Hint(key: "a", label: t("add a section")),
                Hint(key: "x", label: t("reassign a rule")),
                Hint(key: "l", label: russian ? t("english") : t("russian")),
                Hint(key: "p", label: showingDetail ? t("hide the preview") : t("preview")),
                Hint(key: "/", label: t("search")),
                Hint(key: "esc", label: t("back"))]
    }

    private var document: StyleDocument
    private var kind: MapElementKind
    private var list = ListState()
    private var search = SearchPrompt()
    /// Which of a section's own labels to show. A property of the style being edited, not
    /// of the interface, so it is independent of the interface language.
    private var russian = true
    private var message: String?
    private var messageIsError = false
    /// Whether the pane under the list is open. Closed to start with: it costs the list
    /// about a third of its rows.
    private var showingDetail = false

    /// Rebuilt only when the kind changes: parsing every row on every frame is wasted work.
    private var cachedRows: [StyleTypeRow] = []
    private var cachedKind: MapElementKind?

    init(document: StyleDocument, kind: MapElementKind = .point) {
        self.document = document
        self.kind = kind
    }

    private var rows: [StyleTypeRow] {
        if cachedKind != kind {
            cachedRows = document.rows(kind)
            cachedKind = kind
        }
        return cachedRows
    }

    /// Folds the user has opened, by the first code of the run.
    private var expandedFolds: Set<Int> = []

    /// A code that says nothing at all: no rule, no TYP section, no convention. A wall
    /// of such rows tells nobody anything; a run of them folds into one line.
    private func anonymous(_ row: StyleTypeRow) -> Bool {
        !row.isStyled && !row.isEmitted
            && GarminStandard.meaning(kind, row.code, russian: false) == nil
    }

    /// The rows with anonymous runs folded, and each fold's span keyed by the code of
    /// the row that stands for it.
    private var folding: (rows: [StyleTypeRow], spans: [Int: (last: Int, count: Int)]) {
        guard search.query.isEmpty else {
            let q = search.query.lowercased()
            return (rows.filter { row in
                row.hex.contains(q)
                    || row.name(preferringRussian: russian).lowercased().contains(q)
                    || row.section?.englishLabel?.lowercased().contains(q) == true
                    || row.tags.contains { $0.lowercased().contains(q) }
            }, [:])
        }
        let all = rows
        var out: [StyleTypeRow] = []
        var spans: [Int: (last: Int, count: Int)] = [:]
        var i = 0
        while i < all.count {
            let row = all[i]
            if anonymous(row) {
                var j = i
                while j + 1 < all.count, anonymous(all[j + 1]) { j += 1 }
                // An unfold opens the whole run, not one row of it: the run re-derives
                // identically every frame, so touching any of its codes keeps it open.
                let opened = (i...j).contains { expandedFolds.contains(all[$0].code) }
                if j - i + 1 >= 3, !opened {
                    out.append(row)
                    spans[row.code] = (all[j].code, j - i + 1)
                    i = j + 1
                    continue
                }
                for at in i...j { out.append(all[at]) }
                i = j + 1
                continue
            }
            out.append(row)
            i += 1
        }
        return (out, spans)
    }

    private var visible: [StyleTypeRow] { folding.rows }

    /// Opens a fold when the selected row stands for one; says whether it did.
    private func unfoldIfFolded() -> Bool {
        guard let row = visible[safe: list.selected],
              folding.spans[row.code] != nil else { return false }
        expandedFolds.insert(row.code)
        return true
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if search.open { return search.take(key, list: &list) }

        let count = visible.count
        switch key {
        case .up: list.move(-1, count: count)
        case .down: list.move(1, count: count)
        case .pageUp: list.move(-10, count: count, wrap: false)
        case .pageDown: list.move(10, count: count, wrap: false)
        case .home: list.jump(to: 0, count: count)
        case .end: list.jump(to: count - 1, count: count)
        case .left: step(-1)
        case .right, .tab: step(1)

        case .enter:
            if unfoldIfFolded() { return .none }
            guard let row = visible[safe: list.selected] else { return .none }
            guard row.isStyled else {
                say(t("this TYP has no section for %@ — press a to add one", row.hex),
                    error: true)
                return .none
            }
            return .push(TypeEditScreen(style: document.style, kind: kind, code: row.code,
                                        onEdited: { [weak self] in self?.reload() }))

        case .char(let typed):
            // By the key's place on the keyboard, not by its letter, so the commands keep
            // working under a non-Latin layout.
            switch Keys.latin(typed) {
            case "/": search.open = true; message = nil
            case "a":
                if unfoldIfFolded() { return .none }
                return addSection(ctx)
            case "x":
                if unfoldIfFolded() { return .none }
                // The rule set, not the TYP: a code drawn correctly can still be emitted
                // for the wrong thing.
                guard let row = visible[safe: list.selected] else { return .none }
                guard row.isEmitted else {
                    // The inverse gesture: a free code asks which feature to bind here.
                    return .push(ReassignScreen(document: document, kind: kind,
                                                bindingTo: row.code,
                                                onReassigned: { [weak self] in
                                                    self?.reload()
                                                }))
                }
                return .push(ReassignScreen(document: document, kind: kind, code: row.code,
                                            onReassigned: { [weak self] in self?.reload() }))
            case "l": russian.toggle()
            case "p": showingDetail.toggle()
            default: break
            }

        case .esc:
            if search.drop(list: &list) { return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    /// Creates a section for a code this TYP does not style. A TYP covers only what its
    /// author wrote, and the rule set generally emits more codes than that; a code with no
    /// section is drawn by the device.
    private func addSection(_ ctx: AppContext) -> Route {
        guard let row = visible[safe: list.selected] else { return .none }
        guard !row.isStyled else {
            say(t("%@ already has a section — press ⏎ to change it", row.hex), error: true)
            return .none
        }
        guard document.isEditable, let source = document.source,
              let url = document.sourceURL else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return .none
        }
        do {
            let edited = try TypEdit.addSection(in: source, kind: kind, code: row.code,
                                                label: row.tags.first)
            try TypLibrary.save(edited, to: url)
            reload()
            say(t("added a section for %@ — magenta until you draw it", row.hex))
            return .push(TypeEditScreen(style: document.style, kind: kind, code: row.code,
                                        onEdited: { [weak self] in self?.reload() }))
        } catch {
            say(error.localizedDescription, error: true)
            return .none
        }
    }

    /// Re-reads the file after an edit, taking what is on disk rather than what was meant.
    private func reload() {
        document = StyleDocument.load(document.style)
        cachedKind = nil
    }

    /// Moves between points, lines and polygons, keeping the search filter so one query
    /// can be carried across all three.
    private func step(_ delta: Int) {
        let kinds = MapElementKind.allCases
        guard let index = kinds.firstIndex(of: kind) else { return }
        kind = kinds[(index + delta + kinds.count) % kinds.count]
        list = ListState()
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let (shown, spans) = folding

        drawHeader(s, rect: rect, theme: theme, shown: shown.count)

        let detailHeight = showingDetail
            ? detailRows(for: shown[safe: list.selected], within: rect) : 0
        let listTop = rect.y + 3
        let listHeight = max(1, rect.maxY - listTop - detailHeight - 1)

        guard !shown.isEmpty else {
            s.text(rect.x, listTop, search.query.isEmpty
                    ? t("nothing here — the rule set has not been unpacked yet")
                    : t("nothing matches \"%@\"", search.query),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        list.clamp(count: shown.count, visible: listHeight)
        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let row = shown[safe: index] else { break }
            // A column short of the edge: the scroll hint occupies the last one.
            draw(row, into: s, rect: Rect(x: rect.x, y: rect.y, w: rect.w - 1, h: rect.h),
                 y: listTop + i, theme: theme, selected: index == list.selected,
                 fold: spans[row.code])
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)

        if let message {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }

        guard showingDetail, let row = shown[safe: list.selected] else { return }
        drawDetail(row, into: s,
                   rect: Rect(x: rect.x, y: listTop + listHeight + 1, w: rect.w,
                              h: rect.maxY - listTop - listHeight - 1),
                   theme: theme)
    }

    private func drawHeader(_ s: Surface, rect: Rect, theme: Theme, shown: Int) {
        // The three kinds as a strip: one code number means different things in the point,
        // line and polygon tables, so the table has to be on screen.
        var x = rect.x
        for candidate in MapElementKind.allCases {
            let selected = candidate == kind
            let label = " \(candidate.plural) "
            let style = selected
                ? Style(fg: theme.selectionFg, bg: theme.raisedBg, bold: true)
                : Style(fg: theme.faint, bg: theme.appBg)
            x = s.text(x, rect.y, label, style)
            x += 1
        }

        let coverage = document.coverage(kind)
        let summary = document.isReadable
            ? t("%d styled", coverage.both) + " · " + t("%d not", coverage.unstyled.count)
                + (coverage.deliberate.isEmpty
                   ? "" : " · " + t("%d by choice", coverage.deliberate.count))
                + " · " + t("%d unused", coverage.unused.count)
            : t("TYP not readable")
        s.textRight(rect.maxX, rect.y, summary, Style(fg: theme.dim, bg: theme.appBg))

        search.draw(into: s, x: rect.x, y: rect.y + 1, theme: theme)
        s.textRight(rect.maxX, rect.y + 1, t("%d of %d", shown, rows.count),
                    Style(fg: theme.faint, bg: theme.appBg))
        s.hline(rect.x, rect.y + 2, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
    }

    /// How many rows the pane below the list gets: exactly what the selected entry will
    /// put in it, measured as it will be drawn here rather than at full size, since a
    /// picture too wide for the pane is reduced and so occupies fewer rows.
    private func detailRows(for row: StyleTypeRow?, within rect: Rect) -> Int {
        // The rule line above the pane, and the code with its labels under it.
        var wanted = 2

        if let section = row?.section, let picture = section.picture, !section.patternIsBlank {
            // The same share of the width the pane will give it, plus a row for the day
            // and night labels.
            let columns = max(2, section.nightPicture == nil ? rect.w / 2 : rect.w / 3)
            wanted += Widgets.pictureFit(picture, maxColumns: columns).rows + 1
        } else {
            // A line of colours, and for a line the sample drawn under it at its own
            // thickness.
            wanted += row?.section?.kind == .line ? 4 : 2
        }

        // One row per rule that reaches this code.
        wanted += max(1, row?.meaning?.conditions.count ?? 1)

        // The list keeps eight entries whatever the pane wants.
        return max(4, min(wanted, rect.h - 3 - 8))
    }

    /// The width one entry's drawing gets, in cells. A line gets a length rather than a
    /// square, that being its shape; the full drawing is in the detail pane.
    private var previewWidth: Int { kind == .line ? 10 : 2 }

    /// One entry: how the device draws it by day, how it draws it after dark, the code, the
    /// name, and what the rules put on it.
    private func draw(_ row: StyleTypeRow, into s: Surface, rect: Rect, y: Int,
                      theme: Theme, selected: Bool,
                      fold: (last: Int, count: Int)? = nil) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))

        var x = s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ",
                       Style(fg: theme.accent, bg: bg))

        // A folded run of anonymous codes is one line saying what it is; the row it
        // stands on unfolds with ⏎.
        if let fold {
            x += previewWidth * 2 + 2
            let range = "\(row.hex)–\(TypeMeaning.hex(fold.last))"
            x = s.text(x, y, range.padding(toLength: 14, withPad: " ", startingAt: 0),
                       Style(fg: theme.faint, bg: bg))
            s.text(x, y, tn("%d free code(s) — ⏎ unfolds them", fold.count),
                   Style(fg: theme.faint, bg: bg))
            return
        }

        // Day and night side by side. A night the file says nothing about is left blank
        // rather than filled in with the day drawing, as are codes with no section at all:
        // silence in the file is not the same fact as a drawing that repeats.
        if row.isStyled {
            drawPreview(row, night: false, into: s,
                        rect: Rect(x: x, y: y, w: previewWidth, h: 1),
                        theme: theme, background: bg)
            drawPreview(row, night: true, into: s,
                        rect: Rect(x: x + previewWidth + 1, y: y, w: previewWidth, h: 1),
                        theme: theme, background: bg)
        }
        x += previewWidth * 2 + 2

        x = s.text(x, y, row.hex.padding(toLength: 8, withPad: " ", startingAt: 0),
                   Style(fg: row.isStyled ? theme.text : theme.faint, bg: bg))

        let name = row.name(preferringRussian: russian)
        let nameWidth = min(28, max(10, rect.w / 3))
        x = s.text(x, y, truncate(name, to: nameWidth)
                    .padding(toLength: nameWidth, withPad: " ", startingAt: 0),
                   Style(fg: selected ? theme.selectionFg : theme.text, bg: bg, bold: selected))
        x += 1

        // The trailing note is the only coloured part of the row.
        let (note, noteColour) = state(of: row, theme: theme)
        let noteWidth = note.isEmpty ? 0 : note.count + 2
        let tagRoom = max(0, rect.maxX - x - noteWidth)
        if tagRoom > 4 {
            s.text(x, y, truncate(row.tagColumn(preferringRussian: russian), to: tagRoom),
                   Style(fg: theme.faint, bg: bg))
        }
        if !note.isEmpty {
            s.textRight(rect.maxX, y, note, Style(fg: noteColour, bg: bg))
        }
    }

    /// The type as the device draws it, in the room the row has for it. Scaled rather than
    /// cropped, each cell the average of what it stands for, and drawn in the top half of
    /// the row so that adjacent rows do not run into one column of colour.
    private func drawPreview(_ row: StyleTypeRow, night: Bool, into s: Surface, rect: Rect,
                             theme: Theme, background: Color) {
        guard rect.w > 0 else { return }
        Widgets.halfRow(s, x: rect.x, y: rect.y,
                        colours: previewColours(row, night: night, width: rect.w,
                                                on: background),
                        background: background)
    }

    /// What that room comes down to: one colour per cell, nil where nothing is drawn.
    private func previewColours(_ row: StyleTypeRow, night: Bool, width: Int,
                                on background: Color) -> [Color?] {
        guard let section = row.section else { return [] }

        if let picture = night ? section.nightPicture : section.picture,
           !TypeBrowserScreen.isBlank(picture) {
            return Widgets.colourRow(picture, width: width, on: background)
        }

        // No picture on this side of the day, so colours instead — and none for a point,
        // whose colours belong to a picture that has already been drawn.
        guard kind != .point else { return [] }
        let slots = night ? section.colourSlots.night : section.colourSlots.day
        guard let fill = slots.first?.colour.flatMap(Color.hex) else { return [] }
        // A line keeps its length, that being its shape; a pattern with no visible pixel
        // is drawn this way too.
        return Array(repeating: fill, count: width)
    }

    /// A drawing with no visible pixel in it: a pattern of nothing, or a night block that
    /// exists but is empty.
    private static func isBlank(_ picture: XpmBlock) -> Bool {
        guard let grid = picture.pixels() else { return true }
        return !grid.contains { $0.contains { $0 != nil } }
    }

    /// What, if anything, is worth saying about this code at a glance.
    private func state(of row: StyleTypeRow, theme: Theme) -> (String, Color) {
        // Neither drawn nor emitted: a free number, listed so it can be taken.
        if !row.isStyled && !row.isEmitted { return (t("free"), theme.faint) }
        if !row.isStyled {
            // A gap the file marks as deliberate is not a warning: a style may leave a
            // whole family to the device on purpose.
            return document.isDeliberatelyUnstyled(kind, row.code)
                ? (t("device default, on purpose"), theme.faint)
                : (t("device default"), theme.warn)
        }
        if !row.isEmitted { return (t("never emitted"), theme.faint) }
        // Several meanings on one code is not a fault, but it is why one drawing can be
        // wrong for one of them.
        if row.meaningCount > 1 { return (tn("%d meanings", row.meaningCount), theme.dim) }
        return ("", theme.dim)
    }

    // MARK: The detail pane

    private func drawDetail(_ row: StyleTypeRow, into s: Surface, rect: Rect, theme: Theme) {
        guard rect.h > 2 else { return }
        s.hline(rect.x, rect.y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))

        var y = rect.y + 1
        var x = s.text(rect.x, y, row.hex, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        if let section = row.section {
            for label in [section.englishLabel, section.russianLabel].compactMap({ $0 })
            where !label.isEmpty {
                x = s.text(x + 1, y, "· ", Style(fg: theme.faint, bg: theme.appBg))
                x = s.text(x, y, label, Style(fg: theme.text, bg: theme.appBg))
            }
        }
        y += 1

        // The drawing beside its own facts, as big as the pane will hold it, and beside
        // that the night drawing where the file has one.
        if let picture = row.section?.picture, row.section?.patternIsBlank == false,
           rect.maxY - y > 2 {
            let rows = max(1, rect.maxY - y - 1)
            let night = row.section?.nightPicture
            let columns = max(2, night == nil ? rect.w / 2 : rect.w / 3)
            let fit = Widgets.pictureFit(picture, maxColumns: columns, maxRows: rows)
            Widgets.picture(s, x: rect.x, y: y, picture, background: theme.appBg,
                            maxColumns: columns, maxRows: rows)
            var right = rect.x + fit.columns + 2
            if let night, !TypeBrowserScreen.isBlank(night) {
                Widgets.picture(s, x: right, y: y, night, background: theme.appBg,
                                maxColumns: columns, maxRows: rows)
                s.text(right, y + fit.rows, t("night"),
                       Style(fg: theme.faint, bg: theme.appBg))
                s.text(rect.x, y + fit.rows, t("day"),
                       Style(fg: theme.faint, bg: theme.appBg))
                right += Widgets.pictureFit(night, maxColumns: columns, maxRows: rows).columns + 2
            }
            drawPictureFacts(picture, fit: fit, into: s,
                             rect: Rect(x: right, y: y, w: max(0, rect.maxX - right),
                                        h: max(0, rect.maxY - y)),
                             theme: theme)
            y += max(fit.rows + 1, 3)
        } else {
            y = drawColours(row, into: s, rect: rect, y: y, theme: theme)
        }

        guard y < rect.maxY else { return }

        // Every rule that reaches this code, verbatim.
        if row.tags.isEmpty && row.meaning == nil {
            s.text(rect.x, y, t("no rule in this style emits this code"),
                   Style(fg: theme.warn, bg: theme.appBg))
            return
        }
        for condition in (row.meaning?.conditions ?? []) {
            guard y < rect.maxY else { return }
            let x = s.text(rect.x, y, "· ", Style(fg: theme.faint, bg: theme.appBg))
            s.text(x, y, truncate(condition, to: max(0, rect.maxX - x)),
                   Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }
    }

    /// Size, palette depth and the colours themselves, for a picture.
    private func drawPictureFacts(_ picture: XpmBlock, fit: Widgets.PictureFit,
                                  into s: Surface, rect: Rect, theme: Theme) {
        guard rect.w > 12, rect.h > 0 else { return }
        var y = rect.y
        // The scale is stated only when the drawing was reduced, since single-pixel
        // details are then not on screen.
        let scale = fit.isReduced ? "  ·  " + t("shown at 1:%d", fit.scale) : ""
        s.text(rect.x, y, "\(picture.width)×\(picture.height)  "
                + tn("%d colour(s)", picture.declaredColours) + scale,
               Style(fg: theme.dim, bg: theme.appBg))
        y += 1

        // Hex beside every swatch: the block approximates the colour, the text does not.
        for entry in picture.palette.prefix(max(0, rect.h - 1)) {
            guard y < rect.maxY else { return }
            var x = Widgets.swatch(s, x: rect.x, y: y, colour: entry.colour, width: 2,
                                   theme: theme)
            x += 1
            s.text(x, y, entry.colour ?? t("none"),
                   Style(fg: entry.colour == nil ? theme.faint : theme.text, bg: theme.appBg))
            y += 1
        }
    }

    /// Colours for a line or polygon, which have no picture — day and night, and for a line
    /// with a border, the casing beside the fill.
    private func drawColours(_ row: StyleTypeRow, into s: Surface, rect: Rect, y: Int,
                             theme: Theme) -> Int {
        guard let section = row.section else {
            s.text(rect.x, y, t("not styled by this TYP — the device draws its own"),
                   Style(fg: theme.warn, bg: theme.appBg))
            return y + 1
        }
        let colours = section.colours
        guard !colours.isEmpty else { return y }

        var x = rect.x
        for colour in colours {
            guard x < rect.maxX - 10 else { break }
            x = Widgets.swatch(s, x: x, y: y, colour: colour, width: 2, theme: theme)
            x = s.text(x + 1, y, colour ?? t("none"), Style(fg: theme.text, bg: theme.appBg))
            x += 2
        }
        if let width = section.lineWidth {
            let border = section.borderWidth.map { ", " + t("border %d", $0) } ?? ""
            s.textRight(rect.maxX, y, t("width %d", width) + border,
                        Style(fg: theme.dim, bg: theme.appBg))
        }

        // The line itself, at the thickness the file gives it: two lines differing only in
        // width are otherwise the same pair of colours.
        guard kind == .line, rect.maxY - y > 2 else { return y + 2 }
        let day = section.colourSlots.day
        let sample = Rect(x: rect.x, y: y + 1, w: min(rect.w, 32),
                          h: min(rect.maxY - y - 1, 8))
        let used = Widgets.lineSample(s, rect: sample, fill: day.first?.colour,
                                      casing: day.dropFirst().first?.colour,
                                      width: section.lineWidth, border: section.borderWidth,
                                      background: theme.appBg)
        return y + used + 2
    }
}
