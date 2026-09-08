import XCTest
@testable import kmap

/// The log a run writes to, read by the build screen, the file it leaves behind, and
/// whatever else is attached.
final class LogTests: XCTestCase {

    func testLinesComeBackInTheOrderTheyWereWritten() {
        let log = Log()
        log.step("splitting")
        log.ok("7 tiles")
        log.warn("a tile was dense")
        log.error("mkgmap failed")
        let lines = log.snapshot()
        XCTAssertEqual(lines.map(\.text), ["splitting", "7 tiles", "a tile was dense",
                                           "mkgmap failed"])
        XCTAssertEqual(lines.map(\.kind), [.step, .ok, .plain, .plain])
        XCTAssertEqual(lines.map(\.severity), [.info, .info, .warn, .error])
        XCTAssertEqual(log.count, 4)
    }

    func testEveryEventIsNumberedSoAReaderCanTellItMissedOne() {
        let log = Log()
        for i in 0..<5 { log.append("line \(i)") }
        XCTAssertEqual(log.snapshot().map(\.seq), [1, 2, 3, 4, 5])
    }

    func testWhatIsDroppedAtTheDoorIsNotNumberedEither() {
        // The sequence counts what went out, so a gap in it means a lost event and not
        // a filtered one.
        let log = Log()
        log.append("kept")
        log.debug("dropped")
        log.append("kept too")
        XCTAssertEqual(log.snapshot().map(\.seq), [1, 2])
    }

    func testDetailIsOffUntilItIsAskedFor() {
        let log = Log()
        log.debug("mkgmap --route --index")
        log.output("SEVERE (StyleImpl): line 12")
        XCTAssertEqual(log.count, 0)

        log.showing = .debug
        log.debug("mkgmap --route --index")
        XCTAssertEqual(log.snapshot().map(\.text), ["mkgmap --route --index"])
    }

    func testRaisingTheFloorLeavesWhatWasAlreadySaid() {
        let log = Log()
        log.append("said before")
        log.showing = .error
        log.append("said after")
        XCTAssertEqual(log.snapshot().map(\.text), ["said before"])
    }

    func testAnEventCarriesTheFactsAsWellAsTheSentence() {
        // A reader that wants the tile count should not have to parse English for it.
        let log = Log()
        log.ok("7 tile(s)", stage: "split", fields: ["tiles": 7])
        let event = log.snapshot()[0]
        XCTAssertEqual(event.stage, "split")
        XCTAssertEqual(event.fields["tiles"], .int(7))
    }

    func testAnEmptyLineIsNotKept() {
        // Blank lines would push real ones out of the bounded buffer.
        let log = Log()
        log.append("")
        log.append("\n")
        log.append("\r\n")
        XCTAssertEqual(log.count, 0)
    }

    func testTerminalEscapesAreStrippedRatherThanPaintedIntoTheLog() {
        // A tool drawing its own progress bar would otherwise repaint the screen.
        let log = Log()
        log.append("\u{1B}[32mdone\u{1B}[0m")
        log.append("\u{1B}]0;a title\u{07}building")
        XCTAssertEqual(log.snapshot().map(\.text), ["done", "building"])
    }

    func testTheBufferStopsGrowingAndKeepsTheNewestLines() {
        let log = Log(limit: 10)
        for i in 0..<100 { log.append("line \(i)") }
        XCTAssertEqual(log.count, 10)
        XCTAssertEqual(log.snapshot().first?.text, "line 90")
        XCTAssertEqual(log.snapshot().last?.text, "line 99")
    }

    func testItIsWrittenToFromEveryCoreAtOnceWithoutLosingALine() {
        let log = Log(limit: 100_000)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<500 { log.append("worker \(worker) line \(i)") }
        }
        XCTAssertEqual(log.count, 4000)
    }

    func testAnAttachedSinkSeesEveryEventTheRingDoes() {
        let log = Log()
        let seen = LogRing()
        log.attach(seen, showing: .info)
        log.step("one")
        log.warn("two")
        XCTAssertEqual(seen.snapshot().map(\.text), log.snapshot().map(\.text))
    }

    func testASinkCanAskForDetailTheInterfaceIsNotShowing() {
        // What the file a run leaves behind is for: the screen stays readable, and the
        // record still holds what the tools said.
        let log = Log(showing: .info)
        let record = LogRing()
        log.attach(record, showing: .debug)
        log.append("compiling")
        log.output("SEVERE (StyleImpl): line 12")
        XCTAssertEqual(log.snapshot().map(\.text), ["compiling"])
        XCTAssertEqual(record.snapshot().map(\.text),
                       ["compiling", "SEVERE (StyleImpl): line 12"])
    }

    func testTheNumberingCountsWhatWasMadeNotWhatEachSinkSaw() {
        // A gap in what one reader sees is a line another reader was shown, not a loss.
        let log = Log(showing: .info)
        let record = LogRing()
        log.attach(record, showing: .debug)
        log.append("one")
        log.debug("detail")
        log.append("two")
        XCTAssertEqual(log.snapshot().map(\.seq), [1, 3])
        XCTAssertEqual(record.snapshot().map(\.seq), [1, 2, 3])
    }

    func testTheMirrorFileKeepsTheDetailTheScreenLeavesOut() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-log-\(UUID().uuidString)/build.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let log = Log(mirrorTo: url, showing: .info)
            log.step("compiling")
            log.output("mkgmap: reading style")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "compiling\nmkgmap: reading style\n")
    }

    func testTheMirrorFileHoldsTheSameLines() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-log-\(UUID().uuidString)/build.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let log = Log(mirrorTo: url)
            log.step("one")
            log.append("\u{1B}[1mtwo\u{1B}[0m")
        }                                        // flushed and closed on leaving scope
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "one\ntwo\n")
    }
}
