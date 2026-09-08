import XCTest
@testable import kmap

/// Keys read from a stream that a fixed-size read cuts wherever it likes.
///
/// A held arrow sends three bytes a repeat, so every so often a read ends between them.
/// The tail used to be parsed as its own key: a bare `ESC` left the screen, and a Cyrillic
/// letter lost its second byte.
final class TerminalKeysTests: XCTestCase {

    /// Bytes waiting to be read, handed over a read at a time.
    private final class Script: InputSource {
        var queued: [UInt8]

        init(_ text: String) { queued = Array(text.utf8) }

        func wait(milliseconds: Int32) -> Readiness { queued.isEmpty ? .nothingYet : .ready }

        func read(into buffer: inout [UInt8]) -> Int {
            let count = min(buffer.count, queued.count)
            guard count > 0 else { return -1 }
            for index in 0..<count { buffer[index] = queued[index] }
            queued.removeFirst(count)
            return count
        }
    }

    private func keys(from text: String) -> [KeyEvent] {
        let terminal = Terminal(reading: Script(text))
        var read: [KeyEvent] = []
        while let key = terminal.readKey() { read.append(key) }
        return read
    }

    func testAHeldArrowKeepsEveryRepeatAndSendsNoEscape() {
        // 22 repeats: 66 bytes, so the read at 64 lands inside the last sequence.
        let held = String(repeating: "\u{1B}[B", count: 22)
        let read = keys(from: held)
        XCTAssertEqual(read.count, 22)
        for key in read {
            guard case .down = key else { return XCTFail("read \(key), not a down arrow") }
        }
    }

    func testALetterCutInTwoIsStillTheLetter() {
        // 63 dots, then a two-byte letter across the read boundary.
        let read = keys(from: String(repeating: ".", count: 63) + "й")
        XCTAssertEqual(read.count, 64)
        XCTAssertEqual(read.last, .char("й"))
        XCTAssertEqual(read.last?.command, .char("q"))
    }

    func testBufferedKeysAreTakenWithoutAnotherWait() {
        let terminal = Terminal(reading: Script("\u{1B}[B\u{1B}[B"))
        XCTAssertNotNil(terminal.readKey())
        XCTAssertTrue(terminal.hasBufferedKey)
        XCTAssertNotNil(terminal.readKey())
        XCTAssertFalse(terminal.hasBufferedKey)
    }
}
