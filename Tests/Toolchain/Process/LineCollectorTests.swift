import XCTest

@testable import kmap

/// Splitting a child's output into lines as it arrives in chunks.
final class LineCollectorTests: XCTestCase {
    private func collect(_ chunks: [[UInt8]]) -> [String] {
        var lines: [String] = []
        let collector = LineCollector { lines.append($0) }
        for chunk in chunks { collector.ingest(bytes: chunk) }
        collector.finish()
        return lines
    }

    func testAChunkCutInsideACyrillicLetterLosesNothing() {
        // A pipe hands over whatever fits; a cut inside a two-byte letter used to make the
        // whole chunk undecodable, and every complete line before the cut went with it.
        let text = Array("Way 12 (name=Улица Ленина) dropped\nRGN section too big\nОшибка\n".utf8)
        let cut = text.firstIndex(of: 0xD0)! + 1
        let lines = collect([Array(text[..<cut]), Array(text[cut...])])
        XCTAssertEqual(lines, ["Way 12 (name=Улица Ленина) dropped", "RGN section too big", "Ошибка"])
    }

    func testAByteThatIsNotUTF8SpoilsOnlyItsOwnLine() {
        let lines = collect([Array("good\n".utf8) + [0xFF, 0x41, 0x0A] + Array("after\n".utf8)])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "good")
        XCTAssertEqual(lines[2], "after")
    }

    func testManyLinesInOneChunkArriveOnce() {
        let chunk = Array((1...500).map { "line \($0)" }.joined(separator: "\r\n").utf8) + [0x0A]
        let lines = collect([chunk])
        XCTAssertEqual(lines.count, 500)
        XCTAssertEqual(lines.first, "line 1")
        XCTAssertEqual(lines.last, "line 500")
    }
}
