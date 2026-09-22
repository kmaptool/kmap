import Foundation

/// Owns the terminal: raw mode, the alternate screen, size queries and key input. What the
/// machine must be asked for goes through `Console`; the decoding is `KeyDecoder`'s.
final class Terminal {
    /// The escape sequences the interface sends.
    private enum VT {
        static let alternateScreenOn = "\u{1B}[?1049h"
        static let alternateScreenOff = "\u{1B}[?1049l"
        static let hideCursor = "\u{1B}[?25l"
        static let showCursor = "\u{1B}[?25h"
        static let bracketedPasteOn = "\u{1B}[?2004h"
        static let bracketedPasteOff = "\u{1B}[?2004l"
        static let pushTitle = "\u{1B}[22;0t"
        static let popTitle = "\u{1B}[23;0t"
        static let setTitle = "\u{1B}]0;kmap\u{07}"
        static let clear = "\u{1B}[2J"
        /// Pointer reporting: 1000 for buttons, 1003 for motion, 1006 for the SGR
        /// encoding, which is required for columns past 223.
        static let mouseOn = "\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h"
        static let mouseOff = "\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1000l"
    }

    private var mouseTracking = false
    private var keys: KeyDecoder
    /// Whether the whole screen is to be drawn again rather than the difference. Read and
    /// cleared by the render loop.
    private var repaintWanted = false

    /// The terminal in use, for whoever has to lend it out or put it back: a file dialog,
    /// an interrupt. Held weakly, and behind a lock since an interrupt asks from outside.
    static var shared: Terminal? {
        get { held.withLock { $0.terminal } }
        set { held.withLock { $0.terminal = newValue } }
    }

    private struct Held { weak var terminal: Terminal? }
    private static let held = Locked(Held())

    init(reading source: InputSource = ConsoleInput()) {
        keys = KeyDecoder(reading: source)
    }

    // MARK: Lifecycle

    func start() {
        Terminal.shared = self
        _ = Console.enterRawMode()
        output(VT.alternateScreenOn + VT.hideCursor + VT.bracketedPasteOn)
        output(VT.pushTitle + VT.setTitle)
        output(VT.clear)
        Console.onInterrupt { Terminal.shared?.stop() }
    }

    func stop() {
        setMouseTracking(false)
        output(VT.popTitle + VT.bracketedPasteOff + VT.showCursor + VT.alternateScreenOff)
        Console.restore()
    }

    /// While tracking is on, the terminal forwards clicks instead of handling its own
    /// text selection.
    func setMouseTracking(_ enabled: Bool) {
        guard enabled != mouseTracking else { return }
        mouseTracking = enabled
        output(enabled ? VT.mouseOn : VT.mouseOff)
    }

    /// Remembers the console as it stands, before another program is given it.
    func lend() { Console.lend() }

    /// Takes the console back after another program has had it, and asks for a whole
    /// frame. The file dialog runs as a child that shares this console and leaves the code
    /// page, the modes and the screen its own way.
    func reclaim() {
        Console.reclaim()
        keys.discardPending()
        output(VT.alternateScreenOn + VT.hideCursor + VT.bracketedPasteOn + VT.clear)
        if mouseTracking { output(VT.mouseOn) }
        repaintWanted = true
    }

    func takeRepaintRequest() -> Bool {
        defer { repaintWanted = false }
        return repaintWanted
    }

    // MARK: Size and output

    func size() -> (Int, Int) {
        let window = Console.size()
        return (window.columns, window.rows)
    }

    func output(_ string: String) {
        Console.write(Array(string.utf8))
    }

    // MARK: Input

    /// Whether standard input has ended: hung up, or read back nothing.
    var inputHasEnded: Bool { keys.inputHasEnded }

    /// Whether a key is waiting right now, without waiting for one.
    var hasBufferedKey: Bool { keys.hasBufferedKey }

    /// The next decoded key, or nil if nothing arrived within the poll window.
    func readKey() -> KeyEvent? { keys.readKey() }
}
