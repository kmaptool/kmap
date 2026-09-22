import Foundation

/// The characters the interface draws with, and what a Windows console draws instead.
enum Glyph {
    // Box drawing.
    static let tl: Character = "┌"
    static let tr: Character = "┐"
    static let bl: Character = "└"
    static let br: Character = "┘"
    static let h: Character = "─"
    static let v: Character = "│"
    static let bar: Character = "│"
    static let dot: Character = "·"
    static let arrowRight: Character = "›"
    static let check: Character = "✓"
    static let cross: Character = "✕"
    static let ellipsis: Character = "…"

    // Progress: heavy rule for filled, light rule for empty.
    static let barFill: Character = "━"
    static let barEmpty: Character = "─"

    // A cursor round a colour cell: a thin bar on either edge.
    static let leftEdge: Character = "▏"
    static let rightEdge: Character = "▕"
    // The scroll track and the thumb on it.
    static let track: Character = "│"
    static let thumb: Character = "▐"

    // Half block: one cell carries two square pixels, so a 20x20 icon fits in 20 columns
    // and 10 rows.
    static let lowerHalf: Character = "▄"

    /// The turning wheel. Ten braille frames, or four strokes where braille is not drawn:
    /// the substitution maps the ten onto the four, and ten does not divide by four, so
    /// the wheel stepped back at the end of every cycle. A turn takes the same time in
    /// both: three ticks a frame, twelve ticks a turn.
    static let brailleSpinner: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let windowsSpinner: [Character] = ["|", "/", "-", "\\"]
    /// Ticks a spinner frame stays on screen.
    static let spinnerTicksPerFrame = 3

    #if os(Windows)
    static let spinner = windowsSpinner
    #else
    static let spinner = brailleSpinner
    #endif

    /// The two keys named by a picture rather than a word. Windows consoles draw them as
    /// hollow boxes, and a key nobody can read is a key nobody presses, so there they are
    /// spelled out; the hint bar lays out from the text and takes the room.
    #if os(Windows)
    static let enter = "Enter"
    static let tab = "Tab"
    #else
    static let enter = "⏎"
    static let tab = "⇥"
    #endif

    /// What a Windows console can draw, in place of what it cannot. Consolas and Cascadia
    /// stop at WGL4, and a character outside it comes out as a hollow box. Each is swapped
    /// for one the font carries and one cell wide, so nothing shifts; everything else,
    /// Cyrillic included, passes through, and off Windows nothing is substituted at all.
    static let windowsSubstitutes: [Character: Character] = [
        "✓": "√", "✕": "×", "✗": "×",
        "▏": "│", "▕": "│", "▸": "►", "▹": "►", "◂": "◄",
        // The heavy rules become light ones rather than double ones: the progress bar is
        // drawn filled against empty in two colours, and a double line beside a single one
        // reads as two different things where the Mac shows one line in two shades.
        "━": "─", "┃": "│",
        // A bare key mark drawn in one cell: the word would not fit, and an arrow reads
        // better than a bracket. In a sentence these two are spelled out, see L10n.
        "⏎": "←", "⇥": "→", "＋": "+",
        // The spinner, frame for frame, as the same turning stroke.
        "⠋": "|", "⠙": "/", "⠹": "-", "⠸": "\\", "⠼": "|",
        "⠴": "/", "⠦": "-", "⠧": "\\", "⠇": "|", "⠏": "/"
    ]

    static func drawable(_ ch: Character) -> Character {
        #if os(Windows)
        return windowsSubstitutes[ch] ?? ch
        #else
        return ch
        #endif
    }
}
