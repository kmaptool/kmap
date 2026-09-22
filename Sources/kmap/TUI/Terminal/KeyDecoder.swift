import Foundation

/// Turns the bytes a terminal sends into key events: plain and UTF-8 characters, control
/// keys, CSI and SS3 escapes, SGR pointer reports and bracketed pastes.
struct KeyDecoder {
    /// How long a frame waits for a keystroke before being drawn anyway. The main loop has
    /// no sleep of its own; this wait paces it.
    static let pollMilliseconds: Int32 = 100
    /// How long the tail of a key cut by a read boundary is waited for. The terminal
    /// writes a sequence in one go, so it is there already or it was never a sequence.
    static let splitKeyMilliseconds: Int32 = 3
    /// Bytes read at a time while a paste is collected.
    private static let pasteChunk = 4096
    /// Reads that came back empty before a paste with no end marker is given up on.
    private static let pasteEmptyReadsLimit = 60

    private enum Byte {
        static let esc: UInt8 = 0x1B
        static let csi = UInt8(ascii: "[")
        static let ss3 = UInt8(ascii: "O")
        static let pointer = UInt8(ascii: "<")
        static let separator = UInt8(ascii: ";")
        static let tilde = UInt8(ascii: "~")
        static let enter: UInt8 = 13
        static let newline: UInt8 = 10
        static let tab: UInt8 = 9
        static let backspace: UInt8 = 8
        static let delete: UInt8 = 127
        static let lastControl: UInt8 = 0x1A
        static let releaseFinal = UInt8(ascii: "m")

        static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    }

    /// What a CSI or SS3 sequence ending in a letter means.
    private static let finals: [UInt8: KeyEvent] = [
        UInt8(ascii: "A"): .up, UInt8(ascii: "B"): .down,
        UInt8(ascii: "C"): .right, UInt8(ascii: "D"): .left,
        UInt8(ascii: "H"): .home, UInt8(ascii: "F"): .end,
        UInt8(ascii: "Z"): .backTab
    ]

    /// What a CSI sequence ending in `~` means, by its first parameter. 200 opens a paste.
    private static let tildeKeys: [String: KeyEvent] = [
        "1": .home, "7": .home, "4": .end, "8": .end,
        "5": .pageUp, "6": .pageDown, "3": .delete
    ]
    private static let pasteStart = "200"
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    private var input: InputBuffer

    init(reading source: InputSource) {
        input = InputBuffer(reading: source)
    }

    var inputHasEnded: Bool { input.hasEnded }

    /// Whether a key is waiting right now, decoded or still in the console's own buffer.
    /// Nothing is waited for. A held arrow repeats faster than frames are drawn, and one
    /// key a frame leaves the list moving seconds after the key came up.
    var hasBufferedKey: Bool {
        mutating get { !input.isEmpty || input.isReady(within: 0) }
    }

    /// Whatever a helper program left in the buffer is not a keystroke meant for a screen.
    mutating func discardPending() { input.removeAll() }

    /// The next decoded key, or nil if nothing arrived within the poll window.
    mutating func readKey() -> KeyEvent? {
        if input.isEmpty {
            guard input.fill(within: Self.pollMilliseconds) else { return nil }
        }
        return decode()
    }

    private mutating func decode() -> KeyEvent? {
        guard let b = input.popFirst() else { return nil }
        switch b {
        case Byte.esc: return decodeEscape()
        case Byte.enter: return .enter
        case Byte.newline: return .newline
        case Byte.delete, Byte.backspace: return .backspace
        case Byte.tab: return .tab
        case 0...Byte.lastControl: return .ctrl(Character(UnicodeScalar(b + 96)))
        default: return decodeCharacter(startingWith: b)
        }
    }

    /// A lone ESC, or the introducer of a CSI (`ESC [`) or SS3 (`ESC O`) sequence.
    private mutating func decodeEscape() -> KeyEvent? {
        input.ensure(1, within: Self.splitKeyMilliseconds)
        guard let next = input.first, next == Byte.csi || next == Byte.ss3 else { return .esc }
        _ = input.popFirst()
        input.ensure(1, within: Self.splitKeyMilliseconds)
        guard let c = input.first else { return .esc }
        if c == Byte.pointer {
            _ = input.popFirst()
            return decodeMouse()
        }
        guard Byte.isDigit(c) || c == Byte.separator else {
            _ = input.popFirst()
            return Self.finals[c]
        }
        let params = readParameters(toppingUp: true)
        let final = input.popFirst() ?? 0
        if final == Byte.tilde {
            let first = params.first ?? ""
            return first == Self.pasteStart ? collectPaste() : Self.tildeKeys[first]
        }
        return Self.finals[final]
    }

    /// The digits and semicolons of a parameter list, split on the semicolons.
    private mutating func readParameters(toppingUp: Bool) -> [String] {
        var params: [String] = []
        var current = ""
        while true {
            if toppingUp { input.ensure(1, within: Self.splitKeyMilliseconds) }
            guard let d = input.first, Byte.isDigit(d) || d == Byte.separator else { break }
            if d == Byte.separator {
                params.append(current)
                current = ""
            } else {
                current.append(Character(UnicodeScalar(d)))
            }
            _ = input.popFirst()
        }
        params.append(current)
        return params
    }

    /// An SGR pointer report, `ESC [ < button;column;row M` for a press and `m` for a
    /// release. In the button field bit 5 marks motion and bit 6 upwards marks the wheel.
    private mutating func decodeMouse() -> KeyEvent? {
        let params = readParameters(toppingUp: false)
        guard let final = input.popFirst() else { return nil }
        guard params.count >= 3,
            let button = Int(params[0]),
            let column = Int(params[1]),
            let row = Int(params[2])
        else { return nil }

        // The low two bits name the button; 3 means none, so motion with 3 is a move and
        // motion with any other value is a drag.
        let noButton = button & 3 == 3
        let action: MouseEvent.Action
        if button & 64 != 0 {
            action = button & 1 == 0 ? .scrollUp : .scrollDown
        } else if final == Byte.releaseFinal {
            action = .release
        } else if button & 32 != 0 {
            action = noButton ? .move : .drag
        } else {
            action = .press
        }
        // The terminal counts from one; everything drawn here counts from zero.
        return .mouse(MouseEvent(action: action, x: column - 1, y: row - 1, isPrimary: button & 3 == 0))
    }

    /// A character, taking the continuation bytes a UTF-8 lead byte announces.
    private mutating func decodeCharacter(startingWith b: UInt8) -> KeyEvent? {
        var bytes: [UInt8] = [b]
        let continuation = Self.utf8ContinuationCount(b)
        input.ensure(continuation, within: Self.splitKeyMilliseconds)
        for _ in 0..<continuation {
            if let n = input.popFirst() { bytes.append(n) }
        }
        guard let s = String(bytes: bytes, encoding: .utf8), let ch = s.first else { return nil }
        return .char(ch)
    }

    /// Everything up to the end marker, read with a bounded wait so a paste whose marker
    /// never arrives still terminates.
    private mutating func collectPaste() -> KeyEvent {
        var buf = input.drain()
        var emptyReads = 0
        while Self.index(of: Self.pasteEnd, in: buf) == nil && emptyReads < Self.pasteEmptyReadsLimit {
            guard input.fill(within: Self.pollMilliseconds, size: Self.pasteChunk) else {
                emptyReads += 1
                continue
            }
            buf += input.drain()
            emptyReads = 0
        }
        if let idx = Self.index(of: Self.pasteEnd, in: buf) {
            input.replace(with: Array(buf[(idx + Self.pasteEnd.count)...]))
            return .paste(String(bytes: buf[0..<idx], encoding: .utf8) ?? "")
        }
        return .paste(String(bytes: buf, encoding: .utf8) ?? "")
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    private static func utf8ContinuationCount(_ b: UInt8) -> Int {
        switch b {
        case 0xC0...0xDF: return 1
        case 0xE0...0xEF: return 2
        case 0xF0...0xF7: return 3
        default: return 0
        }
    }
}
