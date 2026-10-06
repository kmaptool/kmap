import Foundation

/// Draws a TYP picture pixel by pixel, two cells to a pixel. Painting points a pixel at a
/// palette entry; changing the entry repaints every pixel using it. Saved on ^S.
final class PixelEditorScreen: Screen {
    var page: Page {
        Page(
            style.name,
            subject: TypeMeaning.hex(code) + " · " + (showingNight ? t("night") : t("day"))
                + (dirty ? " ·" : ""),
            keys: keys
        )
    }

    var wantsMouse: Bool { true }

    private var keys: [Hint] {
        if picker != nil {
            return [
                Hint(key: "↑↓←→", label: t("move")),
                Hint(key: Glyph.tab, label: t("grid · sliders · style")),
                Hint(key: Glyph.enter, label: t("take it")),
                Hint(key: "esc", label: t("back to typing"))
            ]
        }
        if case .confirmDiscard? = prompt {
            return [Hint(key: "y", label: t("leave without saving")), Hint(key: "n", label: t("stay"))]
        }
        if prompt != nil {
            var hints = [Hint(key: Glyph.enter, label: t("apply"))]
            if wantsColour { hints.append(Hint(key: "^P", label: t("pick a colour"))) }
            hints.append(Hint(key: "esc", label: t("cancel")))
            return hints
        }
        // A pattern's 4 colours are fixed by the format.
        let adding = kind == .point ? [Hint(key: "a", label: t("add colour"))] : []
        if focus == .palette {
            return [
                Hint(key: "↑↓", label: t("the colour you paint with")),
                Hint(key: Glyph.tab, label: t("back to the picture"))
            ] + adding + [
                Hint(key: "c", label: t("change colour")),
                Hint(key: "esc", label: t("back"))
            ]
        }
        var hints =
            [
                Hint(key: "↑↓←→", label: t("move")),
                Hint(key: "space", label: t("paint")),
                Hint(key: Glyph.tab, label: t("choose a colour")),
                Hint(key: "i", label: t("pick"))
            ] + adding + [Hint(key: "c", label: t("change colour"))]
        if canResize { hints.append(Hint(key: "s", label: t("size"))) }
        if kind == .point {
            hints.append(Hint(key: "n", label: showingNight ? t("day") : t("night")))
        }
        hints.append(contentsOf: [
            Hint(key: "u", label: t("undo")),
            Hint(key: "^S", label: t("save")),
            Hint(key: "esc", label: t("back"))
        ])
        return hints
    }

    enum Prompt {
        case addColour
        case changeColour(index: Int)
        case size
        /// Leaving with unsaved strokes: back a screen, or out of kmap on ^C.
        case confirmDiscard(quitting: Bool)
    }

    /// The format allows 255; this is the largest that fits a terminal at true size.
    private static let maximumSide = 99
    /// Line patterns are 32 wide and at most 7 deep; polygon hatches are 32 by 32.
    private static let patternWidth = 32
    private static let patternHeight = 32
    private static let deepestLine = 7
    /// Deep enough to undo a stroke, shallow enough not to hold many copies of the picture.
    private static let historyDepth = 64

    private let style: MapStyle
    let kind: MapElementKind
    private let code: Int
    private let onSaved: () -> Void

    private var document: StyleDocument
    private var block: XpmBlock
    private var saved: XpmBlock

    /// A point's night picture shares the day pixels and differs only in palette, so
    /// painting is refused while night is showing.
    private var nightBlock: XpmBlock?
    private var savedNight: XpmBlock?
    /// A night whose pixels are not the day's, as a third-party file may hold: kept as
    /// drawn rather than rebuilt from the day.
    private var nightApart = false
    var showingNight = false
    /// Whether the mouse stroke under way has its undo step yet.
    var strokeRemembered = false

    /// Which half the arrow keys drive; tab moves between them.
    enum Focus { case canvas, palette }

    var focus: Focus = .canvas
    var cursor = (x: 0, y: 0)
    var selected = 0
    /// Both halves and which was showing, so an undo restores what it recorded.
    private var history: [(day: XpmBlock, night: XpmBlock?, wasNight: Bool)] = []
    var prompt: Prompt?
    var draft = ""
    var picker: ColourPicker?

    var wantsColour: Bool {
        switch prompt {
        case .addColour?, .changeColour?: return true
        default: return false
        }
    }
    var message: String?
    var messageIsError = false

    /// Where the canvas was drawn last frame, so a click can be turned into a pixel.
    var canvasOrigin = (x: 0, y: 0)
    /// The first pixel on screen: a picture larger than the terminal shows a window that
    /// follows the cursor.
    var canvasScroll = (x: 0, y: 0)
    /// How many pixels across and down the window showed last frame.
    var canvasShown = (across: 0, down: 0)
    /// The first palette entry on screen, and how many are: a long palette is a window
    /// that keeps the colour painted with in sight.
    var paletteScroll = 0
    var paletteShown = 0
    var paletteOrigin = (x: 0, y: 0)

    var dirty: Bool { block != saved || nightBlock != savedNight }

    /// The picture on screen, which is the night one while night is showing.
    var shown: XpmBlock {
        get { showingNight ? (nightBlock ?? block) : block }
        set { if showingNight { nightBlock = newValue } else { block = newValue } }
    }

    /// Only a point: the other grids are fixed by the format.
    var canResize: Bool { kind == .point }

    var sizeRule: String {
        switch kind {
        case .point:
            let side = PixelEditorScreen.maximumSide
            return t("up to %@", "\(side)×\(side)")
        case .line: return t("a line pattern is always 32 wide, and at most 7 deep")
        case .polygon: return t("a polygon hatch is always 32×32")
        }
    }

    init?(style: MapStyle, kind: MapElementKind, code: Int, onSaved: @escaping () -> Void) {
        let document = StyleDocument.load(style)
        guard let section = document.source?.section(kind, code) else { return nil }
        guard
            let picture = section.picture
                ?? PixelEditorScreen.pattern(startingFrom: section)
        else { return nil }
        self.style = style
        self.kind = kind
        self.code = code
        self.onSaved = onSaved
        self.document = document
        self.block = picture
        self.saved = section.picture ?? picture
        if let night = section.nightXpm {
            let aligned = Self.aligned(night, to: picture)
            self.nightBlock = aligned ?? night
            self.savedNight = aligned ?? night
            self.nightApart = aligned == nil
        }
        if section.picture == nil {
            message = t("started a pattern from this type's own colour — save to keep it")
        }
    }

    /// A pattern for a section that has none: every pixel the colour the type is drawn
    /// in, so saving it without a stroke changes nothing.
    private static func pattern(startingFrom section: TypSection) -> XpmBlock? {
        let slots = section.colourSlots
        guard let day = slots.day.first?.colour ?? section.colours.compactMap({ $0 }).first else { return nil }
        // The night fill, not a cased line's border, which shares its slot count.
        let night = slots.night.first?.colour ?? day

        let width = patternWidth
        let height: Int
        switch section.kind {
        case .polygon: height = patternHeight
        case .line: height = min(deepestLine, max(1, section.lineWidth ?? 2))
        case .point: return nil
        }

        // Day ink, day background, night ink, night background: the order the format
        // stores them in. The backgrounds are clear.
        let palette: [(key: String, colour: String?)] = [
            (key: "!", colour: day), (key: ".", colour: nil),
            (key: "3", colour: night), (key: "4", colour: nil)
        ]
        let rows = Array(repeating: String(repeating: "!", count: width), count: height)
        return XpmBlock(
            width: width,
            height: height,
            declaredColours: palette.count,
            charsPerPixel: 1,
            palette: palette,
            rows: rows
        )
    }

    // MARK: Editing

    /// - Parameter remembering: false for the rest of a dragged stroke, which is undone
    ///   as one with its first change.
    /// - Returns: whether a pixel changed.
    @discardableResult
    func paint(x: Int, y: Int, with index: Int, remembering: Bool = true) -> Bool {
        guard x >= 0, x < shown.width, y >= 0, y < shown.height,
            shown.palette.indices.contains(index)
        else { return false }
        guard !showingNight || nightApart else {
            message = t("night shares the day drawing — change its colours, not its pixels")
            messageIsError = false
            return false
        }
        // A line or polygon is 1 bit a pixel: the night pair colours the day's pixels.
        guard kind == .point || index < 2 else {
            message = t("a pattern is painted with its day ink and background — the night pair colours the same pixels")
            messageIsError = true
            return false
        }
        guard var rows = grid(), rows[y][x] != index else { return false }
        if remembering { remember() }
        rows[y][x] = index
        shown = rebuild(rows: rows, like: shown)
        message = nil
        return true
    }

    /// The picture as palette indices.
    func grid() -> [[Int]]? { Self.indices(of: shown) }

    static func indices(of picture: XpmBlock) -> [[Int]] {
        var lookup: [String: Int] = [:]
        for (index, entry) in picture.palette.enumerated() { lookup[entry.key] = index }
        let width = max(1, picture.charsPerPixel)

        var out: [[Int]] = []
        for row in picture.rows.prefix(picture.height) {
            var line: [Int] = []
            var index = row.startIndex
            while index < row.endIndex, line.count < picture.width {
                let next =
                    row.index(index, offsetBy: width, limitedBy: row.endIndex)
                    ?? row.endIndex
                line.append(lookup[String(row[index..<next])] ?? 0)
                index = next
            }
            while line.count < picture.width { line.append(0) }
            out.append(line)
        }
        while out.count < picture.height {
            out.append(Array(repeating: 0, count: picture.width))
        }
        return out
    }

    /// `rows` as a picture shaped as `picture`: a night drawn apart has a size and a key
    /// width of its own.
    private func rebuild(rows: [[Int]], like picture: XpmBlock) -> XpmBlock {
        let palette = picture.palette
        let text = rows.map { line in
            line.map { palette[min($0, palette.count - 1)].key }.joined()
        }
        return XpmBlock(
            width: picture.width,
            height: picture.height,
            declaredColours: palette.count,
            charsPerPixel: picture.charsPerPixel,
            palette: palette,
            rows: text
        )
    }

    func remember() {
        history.append((block, nightBlock, showingNight))
        if history.count > Self.historyDepth { history.removeFirst() }
    }

    func undo() {
        guard let previous = history.popLast() else {
            message = t("nothing to undo")
            messageIsError = false
            return
        }
        block = previous.day
        nightBlock = previous.night
        showingNight = previous.wasNight && previous.night != nil
        cursor = (min(cursor.x, shown.width - 1), min(cursor.y, shown.height - 1))
        selected = min(selected, shown.palette.count - 1)
        message = nil
    }

    /// Adds a colour and selects it. Keys keep their width, so the palette stops at the
    /// key alphabet.
    func addColour(_ text: String) {
        guard kind == .point else {
            message = t("a pattern has an ink and a background, by day and by night — change one with c")
            messageIsError = true
            return
        }
        // A night on the day's drawing has the day's entries, no more: added by day.
        guard !showingNight || nightApart else {
            message = t("night shares the day drawing — add the colour by day, then change it here")
            messageIsError = true
            return
        }
        guard let colour = normalise(text) else {
            message = t("%@ is not a #RRGGBB colour", text)
            messageIsError = true
            return
        }
        let used = Set(shown.palette.map(\.key))
        guard
            let key = PixelEditorScreen.alphabet
                .map({ String($0) })
                .first(where: { !used.contains($0) && $0.count == shown.charsPerPixel })
        else {
            message = t("this picture has no room for another colour")
            messageIsError = true
            return
        }
        remember()
        var palette = shown.palette
        palette.append((key: key, colour: colour))
        shown = XpmBlock(
            width: shown.width,
            height: shown.height,
            declaredColours: palette.count,
            charsPerPixel: shown.charsPerPixel,
            palette: palette,
            rows: shown.rows
        )
        selected = palette.count - 1
        message = t("added %@ — it paints nothing until you use it", colour ?? t("none"))
        messageIsError = false
    }

    func changeColour(_ index: Int, to text: String) {
        guard shown.palette.indices.contains(index) else { return }
        guard let colour = normalise(text) else {
            message = t("%@ is not a #RRGGBB colour", text)
            messageIsError = true
            return
        }
        let changed = shown.replacingColour(
            at: index,
            with: colour.flatMap { TypEdit.keepingAlpha($0, typed: text, of: shown.palette[index].colour) }
        )
        // What mkgmap would refuse at the next build, refused now.
        if kind != .point, let refused = TypEdit.refusal(ofSimple: changed.palette.map(\.colour)) {
            message = refused.localizedDescription
            messageIsError = true
            return
        }
        remember()
        shown = changed
        message = nil
    }

    /// `20x20`, or one number for a square.
    func resize(_ text: String) {
        let parts = text.lowercased()
            .split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == " " })
            .compactMap { Int($0) }
        let width: Int
        let height: Int
        switch parts.count {
        case 1: width = parts[0]; height = parts[0]
        case 2: width = parts[0]; height = parts[1]
        default:
            message = t("write it as 20x20, or one number for a square")
            messageIsError = true
            return
        }
        let limit = PixelEditorScreen.maximumSide
        guard width > 0, height > 0, width <= limit, height <= limit else {
            message = t("between 1 and %d — %@", limit, sizeRule)
            messageIsError = true
            return
        }
        guard width != block.width || height != block.height else { return }

        let shrinking = width < block.width || height < block.height
        // Night follows, or the 2 halves of 1 icon would differ in shape. Sharing the
        // day's drawing, it pads with the day's keys: with one clear at night as well, or
        // the new ground shows in the night colour of the day's clear.
        var source = block
        var clearAt: Int?
        var shared = nightBlock.map { nightApart ? $0 : Self.night($0, onTheDrawingOf: block) }
        if !nightApart, var night = shared {
            clearAt = source.palette.indices.first {
                source.palette[$0].colour == nil && night.palette[$0].colour == nil
            }
            let used = Set(source.palette.map(\.key))
            if clearAt == nil, source.palette.count < XpmBlock.mostColours,
                let key = (0...source.palette.count).lazy.map({ XpmBlock.key($0, width: max(1, source.charsPerPixel)) })
                    .first(where: { !used.contains($0) })
            {
                source = source.adding((key: key, colour: nil))
                night = night.adding((key: key, colour: nil))
                clearAt = source.palette.count - 1
                shared = night
            }
        }
        let day = source.resized(width: width, height: height, clearAt: clearAt)
        let night = shared.map {
            nightApart ? $0.resized(width: width, height: height) : Self.night($0, onTheDrawingOf: day)
        }
        // Grown, a picture needs a clear colour for the new ground, and a full palette has
        // no key left for one.
        guard day.width == width, day.height == height, night.map({ $0.width == width && $0.height == height }) ?? true
        else {
            message =
                block.palette.isEmpty
                ? t("a true-colour picture is not resized here") : t("this picture has no room for another colour")
            messageIsError = true
            return
        }
        remember()
        block = day
        nightBlock = night
        cursor = (min(cursor.x, width - 1), min(cursor.y, height - 1))
        selected = min(selected, shown.palette.count - 1)
        message =
            shrinking
            ? t("cropped to %@ — u puts it back", "\(width)×\(height)")
            : t("grown to %@, the new ground clear", "\(width)×\(height)")
        messageIsError = false
    }

    private func normalise(_ text: String) -> String?? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if meansNone(value) { return String?.none as String?? }
        guard Color.hex(value) != nil else { return nil }
        return TypSource.withAlpha(nil, on: "#" + value.replacingOccurrences(of: "#", with: "").uppercased())
    }

    private static let alphabet = XpmBlock.keyAlphabet

    /// Switches between day and night, starting a night version from the day where
    /// there is none.
    func toggleNight() {
        if showingNight {
            showingNight = false
            selected = min(selected, block.palette.count - 1)
            message = nil
            return
        }
        guard let night = nightBlock else {
            // From the day as it is on screen, edits not yet saved and size included.
            remember()
            nightBlock = block
            showingNight = true
            selected = 0
            message = t("night started from the day drawing — change its colours, then save")
            messageIsError = false
            return
        }
        // The night is the day's drawing in its own colours: brought onto the day's pixels.
        if !nightApart { nightBlock = Self.night(night, onTheDrawingOf: block) }
        cursor = (min(cursor.x, block.width - 1), min(cursor.y, block.height - 1))
        showingNight = true
        selected = min(selected, (nightBlock?.palette.count ?? 1) - 1)
        message =
            nightApart
            ? t("night: drawn apart from the day, kept as it is")
            : t("night: the same drawing, its own colours")
        messageIsError = false
    }

    /// `night` re-keyed onto the day's palette, each day colour taking the night colour
    /// found under its pixels; nil where the 2 are drawn apart: a size of their own,
    /// or 1 day colour under 2 night ones.
    static func aligned(_ night: XpmBlock, to day: XpmBlock) -> XpmBlock? {
        guard night.width == day.width, night.height == day.height else { return nil }
        let dayGrid = indices(of: day)
        let nightGrid = indices(of: night)
        var under: [Int: Int] = [:]
        for (dayRow, nightRow) in zip(dayGrid, nightGrid) {
            for (d, n) in zip(dayRow, nightRow) {
                guard night.palette.indices.contains(n) else { return nil }
                if let seen = under[d] {
                    guard night.palette[seen].colour == night.palette[n].colour else { return nil }
                } else {
                    under[d] = n
                }
            }
        }
        // A day colour no pixel uses keeps the night colour in its place.
        let palette = day.palette.enumerated().map { at, entry in
            let n = under[at] ?? (at < night.palette.count ? at : nil)
            return (key: entry.key, colour: n.map { night.palette[$0].colour } ?? entry.colour)
        }
        let keyed = XpmBlock(
            width: day.width,
            height: day.height,
            declaredColours: palette.count,
            charsPerPixel: day.charsPerPixel,
            palette: palette,
            rows: day.rows
        )
        return Self.night(keyed, onTheDrawingOf: day)
    }

    /// `night` on the pixels of `day`: each entry in its night colour, or its day colour
    /// where the night has none.
    static func night(_ night: XpmBlock, onTheDrawingOf day: XpmBlock) -> XpmBlock {
        let palette = day.palette.enumerated().map { at, entry in
            (key: entry.key, colour: at < night.palette.count ? night.palette[at].colour : entry.colour)
        }
        return XpmBlock(
            width: day.width,
            height: day.height,
            declaredColours: palette.count,
            charsPerPixel: day.charsPerPixel,
            palette: palette,
            rows: day.rows
        )
    }

    // MARK: Saving

    func save() {
        guard let source = document.source, let url = document.sourceURL else { return }
        guard document.isEditable else {
            message = t("this style is read-only — take an editable copy first")
            messageIsError = true
            return
        }
        do {
            var edited = try TypEdit.setPicture(
                in: source,
                kind: kind,
                code: code,
                to: block,
                // The block the file has: a point may carry a plain `Xpm=`.
                tag: kind == .point && document.source?.section(.point, code)?.dayXpm != nil ? "DayXpm" : nil
            )
            let written = nightBlock.map { nightApart ? $0 : Self.night($0, onTheDrawingOf: block) }
            if let nightBlock = written {
                // Added to the file first where it is not there yet; both halves land in one save.
                var next = TypSource.parse(edited)
                if next.section(.point, code)?.nightXpm == nil {
                    edited = try TypEdit.addNightPicture(in: next, code: code)
                    next = TypSource.parse(edited)
                }
                edited = try TypEdit.setPicture(
                    in: next,
                    kind: kind,
                    code: code,
                    to: nightBlock,
                    tag: "NightXpm"
                )
            }
            try TypLibrary.save(edited, to: url)
            document = StyleDocument.load(style)
            saved = block
            nightBlock = written
            savedNight = written
            history.removeAll()
            onSaved()
            message = t("saved")
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }
}
