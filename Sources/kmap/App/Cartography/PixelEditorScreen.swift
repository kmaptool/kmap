import Foundation

/// Draws a TYP picture pixel by pixel, two terminal cells to a pixel so a pixel is roughly
/// square and a click names one row. The picture is palette-indexed: painting points a pixel
/// at an entry, and changing that entry repaints every pixel using it. Nothing is written
/// until it is saved.
final class PixelEditorScreen: Screen {

    var page: Page {
        Page(style.name,
             subject: TypeMeaning.hex(code) + " · " + (showingNight ? t("night") : t("day"))
                 + (dirty ? " ·" : ""),
             keys: keys)
    }

    var wantsMouse: Bool { true }

    private var keys: [Hint] {
        if picker != nil {
            return [Hint(key: "↑↓←→", label: t("move")),
                    Hint(key: Glyph.tab, label: t("grid · sliders · style")),
                    Hint(key: Glyph.enter, label: t("take it")),
                    Hint(key: "esc", label: t("back to typing"))]
        }
        if prompt != nil {
            var hints = [Hint(key: Glyph.enter, label: t("apply"))]
            if wantsColour { hints.append(Hint(key: "^P", label: t("pick a colour"))) }
            hints.append(Hint(key: "esc", label: t("cancel")))
            return hints
        }
        if focus == .palette {
            return [Hint(key: "↑↓", label: t("the colour you paint with")),
                    Hint(key: Glyph.tab, label: t("back to the picture")),
                    Hint(key: "a", label: t("add colour")),
                    Hint(key: "c", label: t("change colour")),
                    Hint(key: "esc", label: t("back"))]
        }
        var hints = [Hint(key: "↑↓←→", label: t("move")),
                     Hint(key: "space", label: t("paint")),
                     Hint(key: Glyph.tab, label: t("choose a colour")),
                     Hint(key: "i", label: t("pick")),
                     Hint(key: "a", label: t("add colour")),
                     Hint(key: "c", label: t("change colour"))]
        if canResize { hints.append(Hint(key: "s", label: t("size"))) }
        if kind == .point {
            hints.append(Hint(key: "n", label: showingNight ? t("day") : t("night")))
        }
        hints.append(contentsOf: [Hint(key: "u", label: t("undo")),
                                  Hint(key: "^S", label: t("save")),
                                  Hint(key: "esc", label: t("back"))])
        return hints
    }

    /// What a typed value is for, while one is being typed.
    enum Prompt {
        case addColour
        case changeColour(index: Int)
        case size
        case confirmDiscard
    }

    /// The largest grid offered. The format stores a point's width in one byte, so 255 is
    /// the format ceiling; 99 is the largest that still fits a terminal at true size.
    private static let maximumSide = 99

    private let style: MapStyle
    let kind: MapElementKind
    private let code: Int
    private let onSaved: () -> Void

    private var document: StyleDocument
    private var block: XpmBlock
    private var saved: XpmBlock

    /// The night picture of a point, where it has one, and whether it is the one on screen.
    /// Night shares the day pixels and differs only in palette, so painting is refused while
    /// night is showing.
    private var nightBlock: XpmBlock?
    private var savedNight: XpmBlock?
    var showingNight = false

    /// Which half of the screen the arrow keys drive: the cursor in the picture, or the
    /// palette entry being painted with. Tab moves between them.
    enum Focus { case canvas, palette }

    var focus: Focus = .canvas
    var cursor = (x: 0, y: 0)
    var selected = 0
    /// Each entry is the whole picture state — both halves and which was showing — so
    /// an undo after `n` restores the block it recorded, not whichever is on screen now.
    private var history: [(day: XpmBlock, night: XpmBlock?, wasNight: Bool)] = []
    var prompt: Prompt?
    var draft = ""
    var picker: ColourPicker?

    /// Whether what is being typed is a colour, and so whether a palette would help.
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
    var paletteOrigin = (x: 0, y: 0)

    var dirty: Bool { block != saved || nightBlock != savedNight }

    /// The picture on screen, which is the night one while night is showing.
    var shown: XpmBlock {
        get { showingNight ? (nightBlock ?? block) : block }
        set { if showingNight { nightBlock = newValue } else { block = newValue } }
    }

    /// Whether the grid can be resized: only for a point. A line pattern is always 32 wide
    /// and at most 7 deep, the thickness being stored in three bits; a polygon hatch is
    /// always 32×32.
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
        guard let picture = section.picture
                ?? PixelEditorScreen.pattern(startingFrom: section) else { return nil }
        self.style = style
        self.kind = kind
        self.code = code
        self.onSaved = onSaved
        self.document = document
        self.block = picture
        self.saved = section.picture ?? picture
        self.nightBlock = section.nightXpm
        self.savedNight = section.nightXpm
        if section.picture == nil {
            message = t("started a pattern from this type's own colour — save to keep it")
        }
    }

    /// A pattern for a section that has none: every pixel is the colour the type is already
    /// drawn in, so saving it without a stroke leaves the drawing unchanged. The grid comes
    /// from the format: 32×32 for a polygon hatch, 32 by the line thickness for a line.
    private static func pattern(startingFrom section: TypSection) -> XpmBlock? {
        let colours = section.colours.compactMap { $0 }
        guard let day = colours.first else { return nil }
        let night = colours.count > 2 ? colours[2] : (colours.count > 1 ? colours[1] : day)

        let width = 32
        let height: Int
        switch section.kind {
        case .polygon: height = 32
        case .line: height = min(7, max(1, section.lineWidth ?? 2))
        case .point: return nil
        }

        // Day ink, day background, night ink, night background: the order a patterned
        // element stores them in. The backgrounds are clear, so erasing shows the ground.
        let palette: [(key: String, colour: String?)] = [
            (key: "!", colour: day), (key: ".", colour: nil),
            (key: "3", colour: night), (key: "4", colour: nil)
        ]
        let rows = Array(repeating: String(repeating: "!", count: width), count: height)
        return XpmBlock(width: width, height: height, declaredColours: palette.count,
                        charsPerPixel: 1, palette: palette, rows: rows)
    }

    // MARK: Editing

    /// Points a pixel at a palette entry. Records the state first, so it can be undone.
    func paint(x: Int, y: Int, with index: Int) {
        guard x >= 0, x < block.width, y >= 0, y < block.height,
              shown.palette.indices.contains(index) else { return }
        guard !showingNight else {
            message = t("night shares the day drawing — change its colours, not its pixels")
            messageIsError = false
            return
        }
        guard var rows = grid(), rows[y][x] != index else { return }
        remember()
        rows[y][x] = index
        block = rebuild(rows: rows, palette: block.palette)
        message = nil
    }

    /// The picture as palette indices, which is what painting actually changes.
    func grid() -> [[Int]]? {
        let picture = shown
        var lookup: [String: Int] = [:]
        for (index, entry) in picture.palette.enumerated() { lookup[entry.key] = index }
        let width = max(1, picture.charsPerPixel)

        var out: [[Int]] = []
        for row in picture.rows.prefix(picture.height) {
            var line: [Int] = []
            var index = row.startIndex
            while index < row.endIndex, line.count < picture.width {
                let next = row.index(index, offsetBy: width, limitedBy: row.endIndex)
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

    private func rebuild(rows: [[Int]], palette: [(key: String, colour: String?)]) -> XpmBlock {
        let width = max(1, block.charsPerPixel)
        let text = rows.map { line in
            line.map { palette[min($0, palette.count - 1)].key }.joined()
        }
        _ = width
        return XpmBlock(width: block.width, height: block.height,
                        declaredColours: palette.count, charsPerPixel: block.charsPerPixel,
                        palette: palette, rows: text)
    }

    private func remember() {
        history.append((block, nightBlock, showingNight))
        // Bounded: deep enough to undo a stroke, shallow enough not to hold many copies
        // of the picture.
        if history.count > 64 { history.removeFirst() }
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

    /// Adds a colour to the palette and selects it. Keys keep their current width, since
    /// widening one would renumber every pixel, so the palette stops at the key alphabet.
    func addColour(_ text: String) {
        guard let colour = normalise(text) else {
            message = t("%@ is not a #RRGGBB colour", text)
            messageIsError = true
            return
        }
        let used = Set(shown.palette.map(\.key))
        guard let key = PixelEditorScreen.alphabet
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
        shown = XpmBlock(width: shown.width, height: shown.height,
                         declaredColours: palette.count, charsPerPixel: shown.charsPerPixel,
                         palette: palette, rows: shown.rows)
        selected = palette.count - 1
        message = t("added %@ — it paints nothing until you use it", colour ?? t("none"))
        messageIsError = false
    }

    /// Changes one palette entry, which repaints every pixel pointing at it.
    func changeColour(_ index: Int, to text: String) {
        guard shown.palette.indices.contains(index) else { return }
        guard let colour = normalise(text) else {
            message = t("%@ is not a #RRGGBB colour", text)
            messageIsError = true
            return
        }
        remember()
        shown = shown.replacingColour(at: index, with: colour)
        message = nil
    }

    /// Changes the grid. `20x20`, or one number for a square.
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

        remember()
        // Cropping discards what lay outside; the history entry above makes it undoable.
        let shrinking = width < block.width || height < block.height
        block = block.resized(width: width, height: height)
        // Night follows, or the two halves of one icon would be different shapes.
        nightBlock = nightBlock?.resized(width: width, height: height)
        cursor = (min(cursor.x, width - 1), min(cursor.y, height - 1))
        selected = min(selected, shown.palette.count - 1)
        message = shrinking ? t("cropped to %@ — u puts it back", "\(width)×\(height)")
                            : t("grown to %@, the new ground clear", "\(width)×\(height)")
        messageIsError = false
    }

    private func normalise(_ text: String) -> String?? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if meansNone(value) { return String?.none as String?? }
        guard Color.hex(value) != nil else { return nil }
        return "#" + value.replacingOccurrences(of: "#", with: "").uppercased()
    }

    private static let alphabet = XpmBlock.keyAlphabet

    /// Switches between the day drawing and the night one, offering to start a night
    /// version where there is none.
    func toggleNight() {
        if showingNight { showingNight = false; message = nil; return }
        guard nightBlock != nil else {
            // Started from the day drawing: a night version is the same shape in colours
            // for a dark screen.
            guard let source = document.source else { return }
            do {
                let edited = try TypEdit.addNightPicture(in: source, code: code)
                // Recorded first: starting the night version is an edit like any other.
                remember()
                nightBlock = TypSource.parse(edited).section(.point, code)?.nightXpm
                showingNight = nightBlock != nil
                selected = 0
                message = showingNight
                    ? t("night started from the day drawing — change its colours, then save")
                    : t("could not start a night version")
                messageIsError = !showingNight
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            return
        }
        showingNight = true
        selected = min(selected, (nightBlock?.palette.count ?? 1) - 1)
        message = t("night: the same drawing, its own colours")
        messageIsError = false
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
            var edited = try TypEdit.setPicture(in: source, kind: kind, code: code, to: block,
                                                tag: kind == .point ? "DayXpm" : nil)
            if let nightBlock {
                // The night block may not be in the file yet, so it is added before it is
                // written. Both halves land in one save, keeping the two shapes identical.
                var next = TypSource.parse(edited)
                if next.section(.point, code)?.nightXpm == nil {
                    edited = try TypEdit.addNightPicture(in: next, code: code)
                    next = TypSource.parse(edited)
                }
                edited = try TypEdit.setPicture(in: next, kind: kind, code: code,
                                                to: nightBlock, tag: "NightXpm")
            }
            try TypLibrary.save(edited, to: url)
            document = StyleDocument.load(style)
            saved = block
            savedNight = nightBlock
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
