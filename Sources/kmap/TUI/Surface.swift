import Foundation

/// An in-memory grid of styled cells. Screens draw into it; `compose()` emits a full ANSI frame.
final class Surface {
    /// A string the renderer had to cut short, with the position it was drawn at.
    /// Collected only inside `collectClipped(_:)`.
    struct Clip: Hashable {
        let x: Int, y: Int
        let text: String
        /// Identity is the position alone, so the same draw call compares equal across
        /// languages.
        static func == (a: Clip, b: Clip) -> Bool { a.x == b.x && a.y == b.y }
        func hash(into hasher: inout Hasher) { hasher.combine(x); hasher.combine(y) }
    }

    nonisolated(unsafe) private static var clips: [Clip]?
    private static let clipGate = NSLock()

    static func collectClipped<T>(_ body: () throws -> T) rethrows -> (T, [Clip]) {
        clipGate.lock(); clips = []; clipGate.unlock()
        defer { clipGate.lock(); clips = nil; clipGate.unlock() }
        let out = try body()
        clipGate.lock(); let found = clips ?? []; clipGate.unlock()
        return (out, found)
    }

    private static func noteClipped(at x: Int, _ y: Int, _ string: String) {
        clipGate.lock()
        if clips != nil, !string.isEmpty { clips?.append(Clip(x: x, y: y, text: string)) }
        clipGate.unlock()
    }

    private(set) var width = 0
    private(set) var height = 0
    private var cells: [Cell] = []

    /// Whether `compose()` emits 24-bit colour or folds it onto the 256-entry palette.
    var trueColour = TerminalCapabilities.trueColour

    func resize(_ w: Int, _ h: Int) {
        guard w != width || h != height else { return }
        width = max(0, w)
        height = max(0, h)
        cells = Array(repeating: Cell(), count: width * height)
    }

    var bounds: Rect { Rect(x: 0, y: 0, w: width, h: height) }

    func clear(_ style: Style) {
        for i in cells.indices { cells[i] = Cell(ch: " ", style: style) }
    }

    @inline(__always)
    private func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// The cell at a position, or nil outside the grid.
    func cell(_ x: Int, _ y: Int) -> Cell? {
        guard inBounds(x, y) else { return nil }
        return cells[y * width + x]
    }

    /// The grid as plain text, one line per row with trailing spaces removed. Not used by
    /// the renderer.
    func asText() -> String {
        (0..<height).map { y in
            String((0..<width).map { x in cells[y * width + x].ch })
                .replacingOccurrences(of: "\u{0}", with: " ")
        }
        .map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        .joined(separator: "\n")
    }

    func put(_ x: Int, _ y: Int, _ ch: Character, _ style: Style) {
        guard inBounds(x, y) else { return }
        // Every character on screen passes here, which is where a console that cannot
        // draw one is given something it can.
        cells[y * width + x] = Cell(ch: Glyph.drawable(ch), style: style)
    }

    /// Draws text starting at (x, y), clipped to `limit` columns and the surface bounds.
    @discardableResult
    func text(_ x: Int, _ y: Int, _ string: String, _ style: Style, limit: Int = .max) -> Int {
        guard y >= 0, y < height else { return x }
        let available = width - x
        guard available > 0 else { return x }
        var cx = x
        let stopX = x + min(limit, available)
        for ch in string {
            if cx >= stopX {
                // The rest of the string is dropped; record it for `collectClipped(_:)`.
                Surface.noteClipped(at: x, y, string)
                break
            }
            if ch == "\t" {
                for _ in 0..<4 where cx < stopX { put(cx, y, " ", style); cx += 1 }
                continue
            }
            // Control characters are never stored: they would reach the terminal verbatim.
            if let scalar = ch.unicodeScalars.first,
               scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                continue
            }
            put(cx, y, ch, style)
            cx += 1
        }
        return cx
    }

    /// Draws text right-aligned so that it ends at `rightEdge` (exclusive).
    @discardableResult
    func textRight(_ rightEdge: Int, _ y: Int, _ string: String, _ style: Style) -> Int {
        let x = max(0, rightEdge - string.count)
        return text(x, y, string, style)
    }

    func fill(_ rect: Rect, _ style: Style, _ ch: Character = " ") {
        guard rect.w > 0, rect.h > 0 else { return }
        for yy in rect.y..<rect.maxY {
            for xx in rect.x..<rect.maxX {
                put(xx, yy, ch, style)
            }
        }
    }

    func hline(_ x: Int, _ y: Int, _ length: Int, _ ch: Character, _ style: Style) {
        guard length > 0 else { return }
        for i in 0..<length { put(x + i, y, ch, style) }
    }

    func vline(_ x: Int, _ y: Int, _ length: Int, _ ch: Character, _ style: Style) {
        guard length > 0 else { return }
        for i in 0..<length { put(x, y + i, ch, style) }
    }

    /// Square box with an optional inline title.
    func box(_ rect: Rect, _ style: Style, title: String? = nil, titleStyle: Style? = nil) {
        guard rect.w >= 2, rect.h >= 2 else { return }
        let x0 = rect.x, y0 = rect.y, x1 = rect.maxX - 1, y1 = rect.maxY - 1
        put(x0, y0, Glyph.tl, style)
        put(x1, y0, Glyph.tr, style)
        put(x0, y1, Glyph.bl, style)
        put(x1, y1, Glyph.br, style)
        hline(x0 + 1, y0, rect.w - 2, Glyph.h, style)
        hline(x0 + 1, y1, rect.w - 2, Glyph.h, style)
        for yy in (y0 + 1)..<y1 {
            put(x0, yy, Glyph.v, style)
            put(x1, yy, Glyph.v, style)
        }
        if let title, !title.isEmpty {
            text(x0 + 2, y0, " \(title) ", titleStyle ?? style, limit: max(0, rect.w - 4))
        }
    }

    /// A section caption: dim uppercase label followed by a hairline rule to the right edge.
    func sectionRule(_ rect: Rect, _ y: Int, _ caption: String, labelStyle: Style, ruleStyle: Style) {
        let label = caption.uppercased()
        let end = text(rect.x, y, label, labelStyle, limit: rect.w)
        let ruleStart = end + 1
        if ruleStart < rect.maxX {
            hline(ruleStart, y, rect.maxX - ruleStart, Glyph.h, ruleStyle)
        }
    }

    /// Builds the full-frame ANSI string with run-length style coalescing.
    func compose() -> String {
        var out = "\u{1B}[H"
        out.reserveCapacity(width * height + 256)
        for y in 0..<height {
            out += "\u{1B}[\(y + 1);1H"
            var lastStyle: Style? = nil
            for x in 0..<width {
                let cell = cells[y * width + x]
                if lastStyle != cell.style {
                    out += cell.style.sgr(trueColour: trueColour)
                    lastStyle = cell.style
                }
                out.append(cell.ch)
            }
            out += "\u{1B}[0m"
        }
        return out
    }
}

// MARK: - Text helpers

/// Wraps text to `width` columns, honoring explicit newlines and breaking on spaces when possible.
func wrapText(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    let normalized = text.replacingOccurrences(of: "\t", with: "    ")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        if line.isEmpty { lines.append(""); continue }
        while line.count > width {
            let breakIdx = line.index(line.startIndex, offsetBy: width)
            let head = line[line.startIndex..<breakIdx]
            if let space = head.lastIndex(of: " "), space != line.startIndex {
                lines.append(String(line[line.startIndex..<space]))
                line = String(line[line.index(after: space)...])
            } else {
                lines.append(String(head))
                line = String(line[breakIdx...])
            }
        }
        lines.append(line)
    }
    return lines
}

/// Strips ANSI/VT escape sequences and control characters from text produced by external
/// programs. Tabs and newlines are kept.
func stripControlSequences(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let s = scalars[i]
        if s.value == 0x1B { // ESC — skip the whole sequence
            let next = i + 1 < scalars.count ? scalars[i + 1] : UnicodeScalar(0)
            if next == "[" {
                i += 2
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                i += 1
            } else if next == "]" {
                i += 2
                while i < scalars.count, scalars[i].value != 0x07, scalars[i].value != 0x1B { i += 1 }
                if i < scalars.count, scalars[i].value == 0x1B { i += 1 }
                i += 1
            } else {
                i += 2
            }
            continue
        }
        if s.value == 0x09 || s.value == 0x0A || (s.value >= 0x20 && s.value != 0x7F && !(0x80...0x9F).contains(s.value)) {
            result.unicodeScalars.append(s)
        }
        i += 1
    }
    return result
}

func truncate(_ s: String, to width: Int) -> String {
    guard width > 0 else { return "" }
    guard s.count > width else { return s }
    guard width > 1 else { return String(s.prefix(width)) }
    return String(s.prefix(width - 1)) + String(Glyph.ellipsis)
}
