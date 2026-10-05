import XCTest

@testable import kmap

final class InputBufferEndTests: XCTestCase {
    /// Answers as scripted: each read takes the next count, 0 being an empty read.
    private final class Scripted: InputSource {
        var reads: [Int]
        init(_ reads: [Int]) { self.reads = reads }
        func wait(milliseconds: Int32) -> Readiness { .ready }
        func read(into buffer: inout [UInt8]) -> Int {
            let n = reads.isEmpty ? 0 : reads.removeFirst()
            for i in 0..<n { buffer[i] = 0x61 }
            return n
        }
    }

    /// A raw terminal answers 0 once when another reader took the byte: not the end.
    func testOneEmptyReadIsNotTheEnd() {
        var buffer = InputBuffer(reading: Scripted([0, 1]))
        XCTAssertFalse(buffer.fill(within: 0))
        XCTAssertFalse(buffer.hasEnded)
        XCTAssertTrue(buffer.fill(within: 0))
    }

    /// A closed pipe answers 0 every time: that is the end.
    func testEmptyReadsOverAndOverAreTheEnd() {
        var buffer = InputBuffer(reading: Scripted([]))
        for _ in 0..<3 { _ = buffer.fill(within: 0) }
        XCTAssertTrue(buffer.hasEnded)
    }
}
