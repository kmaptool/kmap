import Foundation

/// Owns the terminal: raw mode, alternate screen, size queries, and key input parsing.
///
/// Escape sequences, key and mouse decoding and the paste collector are platform
/// independent; everything the machine must be asked for goes through `Console`.
final class Terminal {
    private var mouseTracking = false
    private var pending: [UInt8] = []
    private let source: InputSource

    static weak var shared: Terminal?

    init(reading source: InputSource = ConsoleInput()) {
        self.source = source
    }

    // MARK: Lifecycle

    func start() {
        Terminal.shared = self
        _ = Console.enterRawMode()
        output("\u{1B}[?1049h")   // alternate screen buffer
        output("\u{1B}[?25l")     // hide cursor
        output("\u{1B}[?2004h")   // bracketed paste mode
        output("\u{1B}[22;0t")    // push the current window title
        output("\u{1B}]0;kmap\u{07}") // set the window title
        output("\u{1B}[2J")       // clear
        installSignalHandlers()
    }

    /// Turns pointer reporting on or off: 1000 for buttons, 1003 for motion, 1006 for the
    /// SGR encoding, which is required for columns past 223. While it is on, the terminal
    /// forwards clicks instead of handling its own text selection.
    func setMouseTracking(_ enabled: Bool) {
        guard enabled != mouseTracking else { return }
        mouseTracking = enabled
        output(enabled ? "\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h"
                       : "\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1000l")
    }

    /// Remembers the console as it stands, before another program is given it.
    func lend() { Console.lend() }

    /// Takes the console back after another program has had it, and asks for a whole
    /// frame. The file dialog runs as a child that shares this console: it leaves the code
    /// page, the modes and the screen its own way, and what was drawn after that came out
    /// in the wrong characters on a screen the wrong size.
    func reclaim() {
        Console.reclaim()
        // Whatever the dialog left in the buffer is not a keystroke meant for a screen.
        pending.removeAll()
        output("\u{1B}[?1049h")   // the alternate screen, in case it was left
        output("\u{1B}[?25l")     // hide cursor
        output("\u{1B}[?2004h")   // bracketed paste
        output("\u{1B}[2J")       // clear
        if mouseTracking { output("\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h") }
        repaintWanted = true
    }

    /// Whether the whole screen is to be drawn again rather than the difference. Read and
    /// cleared by the render loop.
    private var repaintWanted = false

    func takeRepaintRequest() -> Bool {
        defer { repaintWanted = false }
        return repaintWanted
    }

    func stop() {
        setMouseTracking(false)
        output("\u{1B}[23;0t")    // restore the pushed window title
        output("\u{1B}[?2004l")   // disable bracketed paste
        output("\u{1B}[?25h")     // show cursor
        output("\u{1B}[?1049l")   // leave alternate screen
        Console.restore()
    }

    // MARK: Size / output

    func size() -> (Int, Int) {
        let window = Console.size()
        return (window.columns, window.rows)
    }

    func output(_ string: String) {
        Console.write(Array(string.utf8))
    }

    // MARK: Input

    /// How long a frame waits for a keystroke before being drawn anyway. The main loop has
    /// no sleep of its own; this wait paces it.
    private static let pollMilliseconds: Int32 = 100

    /// Whether there is anything to read, waiting up to `milliseconds` for it. Sets
    /// `inputHasEnded` when the input is at end.
    private func inputIsReady(within milliseconds: Int32) -> Bool {
        switch source.wait(milliseconds: milliseconds) {
        case .ready: return true
        case .nothingYet: return false
        case .ended:
            inputHasEnded = true
            return false
        }
    }

    /// Whether standard input has ended: hung up, or read back nothing. Observed from
    /// reads rather than predicted with `isatty`, which can be wrong before a console is
    /// attached.
    private(set) var inputHasEnded = false

    /// Whether a key is waiting right now, decoded or still in the console's own buffer.
    /// Nothing is waited for. A held arrow repeats faster than frames are drawn, and one
    /// key a frame leaves the list moving seconds after the key came up.
    var hasBufferedKey: Bool { !pending.isEmpty || inputIsReady(within: 0) }

    /// Returns the next decoded key, or nil if nothing arrived within the poll window.
    func readKey() -> KeyEvent? {
        if pending.isEmpty {
            guard inputIsReady(within: Terminal.pollMilliseconds) else { return nil }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = source.read(into: &buf)
            // Zero is end of file, which `poll` reports as readable.
            if n == 0 { inputHasEnded = true }
            if n <= 0 { return nil }
            pending.append(contentsOf: buf[0..<n])
        }
        return parseKey()
    }

    /// Tops the buffer up to `count` bytes if the console has them, waiting briefly.
    ///
    /// A read stops at a fixed size, so a held arrow — three bytes a repeat — is cut in
    /// two every so often. Without this the tail of the escape sequence is parsed as its
    /// own key, and a bare `ESC` leaves the screen.
    @discardableResult
    private func ensure(_ count: Int) -> Bool {
        while pending.count < count {
            guard inputIsReady(within: Terminal.splitKeyMilliseconds) else { return false }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = source.read(into: &buf)
            if n == 0 { inputHasEnded = true }
            if n <= 0 { return false }
            pending.append(contentsOf: buf[0..<n])
        }
        return true
    }

    /// How long the tail of a key cut by a read boundary is waited for. The terminal
    /// writes a sequence in one go, so it is there already or it was never a sequence.
    private static let splitKeyMilliseconds: Int32 = 3

    private func parseKey() -> KeyEvent? {
        guard !pending.isEmpty else { return nil }
        let b = pending.removeFirst()

        switch b {
        case 0x1B: // ESC
            ensure(1)
            guard let next = pending.first, next == 0x5B || next == 0x4F else { return .esc }
            pending.removeFirst() // consume [ or O
            ensure(1)
            guard let c = pending.first else { return .esc }
            if c == 0x3C { // '<' — an SGR pointer report
                pending.removeFirst()
                return parseMouse()
            }
            if (c >= 0x30 && c <= 0x39) || c == 0x3B { // parameterized CSI
                var params: [String] = []
                var current = ""
                while ensure(1), let d = pending.first, (d >= 0x30 && d <= 0x39) || d == 0x3B {
                    if d == 0x3B { params.append(current); current = "" }
                    else { current.append(Character(UnicodeScalar(d))) }
                    pending.removeFirst()
                }
                params.append(current)
                let final = pending.first ?? 0
                if pending.first != nil { pending.removeFirst() }

                switch final {
                case 0x7E: // '~'
                    switch params.first ?? "" {
                    case "200": return collectPaste()
                    case "1", "7": return .home
                    case "4", "8": return .end
                    case "5": return .pageUp
                    case "6": return .pageDown
                    case "3": return .delete
                    default: return nil
                    }
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home
                case 0x46: return .end
                case 0x5A: return .backTab
                default: return nil
                }
            } else {
                pending.removeFirst()
                switch c {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home
                case 0x46: return .end
                case 0x5A: return .backTab
                default: return nil
                }
            }
        case 13: return .enter
        case 10: return .newline
        case 127, 8: return .backspace
        case 9: return .tab
        case 0x00...0x1A:
            return .ctrl(Character(UnicodeScalar(b + 96)))
        default:
            var bytes: [UInt8] = [b]
            let continuation = utf8ContinuationCount(b)
            ensure(continuation)
            for _ in 0..<continuation {
                if let n = pending.first { bytes.append(n); pending.removeFirst() }
            }
            if let s = String(bytes: bytes, encoding: .utf8), let ch = s.first {
                return .char(ch)
            }
            return nil
        }
    }

    /// Decodes an SGR pointer report, `ESC [ < button;column;row M` for a press and `m` for
    /// a release. In the button field bit 5 marks motion and bit 6 upwards marks the wheel.
    private func parseMouse() -> KeyEvent? {
        var params: [String] = []
        var current = ""
        while let d = pending.first, (d >= 0x30 && d <= 0x39) || d == 0x3B {
            if d == 0x3B { params.append(current); current = "" }
            else { current.append(Character(UnicodeScalar(d))) }
            pending.removeFirst()
        }
        params.append(current)
        guard let final = pending.first else { return nil }
        pending.removeFirst()

        guard params.count >= 3,
              let button = Int(params[0]),
              let column = Int(params[1]),
              let row = Int(params[2]) else { return nil }

        let released = final == 0x6D   // 'm'
        // The low two bits name the button; 3 means none, so motion with 3 is a move and
        // motion with any other value is a drag.
        let noButton = button & 3 == 3
        let action: MouseEvent.Action
        if button & 64 != 0 {
            action = button & 1 == 0 ? .scrollUp : .scrollDown
        } else if released {
            action = .release
        } else if button & 32 != 0 {
            action = noButton ? .move : .drag
        } else {
            action = .press
        }
        // The terminal counts from one; everything drawn here counts from zero.
        return .mouse(MouseEvent(action: action, x: column - 1, y: row - 1,
                                 isPrimary: button & 3 == 0))
    }

    private func collectPaste() -> KeyEvent {
        let end: [UInt8] = Array("\u{1B}[201~".utf8)
        var buf = pending
        pending.removeAll()
        var emptyReads = 0
        while indexOf(end, in: buf) == nil && emptyReads < 60 {
            // Bounded waiting, so a paste whose end marker never arrives still terminates.
            guard inputIsReady(within: Terminal.pollMilliseconds) else {
                emptyReads += 1
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = source.read(into: &chunk)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]); emptyReads = 0 } else { emptyReads += 1 }
        }
        if let idx = indexOf(end, in: buf) {
            let content = Array(buf[0..<idx])
            pending = Array(buf[(idx + end.count)...])
            return .paste(String(bytes: content, encoding: .utf8) ?? "")
        }
        return .paste(String(bytes: buf, encoding: .utf8) ?? "")
    }

    private func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    private func utf8ContinuationCount(_ b: UInt8) -> Int {
        switch b {
        case 0xC0...0xDF: return 1
        case 0xE0...0xEF: return 2
        case 0xF0...0xF7: return 3
        default: return 0
        }
    }

    // MARK: Interruption

    private func installSignalHandlers() {
        Console.onInterrupt { Terminal.shared?.stop() }
    }
}

/// Where key bytes come from: the console in the app, and a written script in a test.
protocol InputSource {
    func wait(milliseconds: Int32) -> Readiness
    func read(into buffer: inout [UInt8]) -> Int
}

struct ConsoleInput: InputSource {
    func wait(milliseconds: Int32) -> Readiness {
        Console.waitForInput(milliseconds: milliseconds)
    }

    func read(into buffer: inout [UInt8]) -> Int { Console.read(into: &buffer) }
}
