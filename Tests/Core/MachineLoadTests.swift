import XCTest
@testable import kmap

/// The two numbers the header bar reports: CPU rate and memory in use.
final class MachineLoadTests: XCTestCase {

    func testTheMachineReportsItsMemory() {
        let (load, _) = MachineLoad.read(since: nil)
        XCTAssertGreaterThan(load.totalMemory, 1_000_000_000,
                             "a machine running this has at least a gigabyte")
        XCTAssertGreaterThan(load.usedMemory, 0)
        XCTAssertLessThanOrEqual(load.usedMemory, load.totalMemory)
        XCTAssertTrue((0...1).contains(load.memoryFraction))
    }

    /// A rate needs two readings; the first reports `nil` rather than a zero that would
    /// read as an idle machine.
    func testTheFirstReadingHasNoRate() {
        XCTAssertNil(MachineLoad.read(since: nil).load.cpu)
    }

    func testASecondReadingAfterRealWorkHasARate() async throws {
        let (_, first) = MachineLoad.read(since: nil)
        try XCTSkipUnless(first != nil, "this machine has no CPU counters to read")
        var sink = 0.0
        for i in 0..<4_000_000 { sink += Double(i).squareRoot() }
        XCTAssertGreaterThan(sink, 0)
        try await Task.sleep(nanoseconds: 300_000_000)

        let (load, _) = MachineLoad.read(since: first)
        let cpu = try XCTUnwrap(load.cpu, "two readings a third of a second apart should"
                                + " give a rate")
        XCTAssertTrue((0...1).contains(cpu), "\(cpu) is not a fraction")
    }

    /// Counters that did not move, or that went backwards, yield `nil` so the bar keeps
    /// what it had.
    func testAPairOfReadingsThatSaysNothingAnswersNothing() {
        let now = MachineLoad.Ticks(busy: 500, total: 1_000)
        XCTAssertNil(MachineLoad.rate(from: now, to: now), "no time passed")
        XCTAssertNil(MachineLoad.rate(from: now, to: .init(busy: 400, total: 900)),
                     "counters that went backwards")
        XCTAssertNil(MachineLoad.rate(from: now, to: .init(busy: 400, total: 1_100)),
                     "busy went backwards while total did not")
    }

    func testTheRateIsBusyOverElapsed() {
        let was = MachineLoad.Ticks(busy: 1_000, total: 4_000)
        XCTAssertEqual(MachineLoad.rate(from: was, to: .init(busy: 1_050, total: 4_100)),
                       0.5)
        XCTAssertEqual(MachineLoad.rate(from: was, to: .init(busy: 1_000, total: 4_100)),
                       0.0, "idle is a real answer, unlike no answer at all")
        // Busy beyond the elapsed time is clamped to full.
        XCTAssertEqual(MachineLoad.rate(from: was, to: .init(busy: 1_500, total: 4_100)),
                       1.0)
    }

    func testMemoryReadsAsUsedOutOfTotal() {
        XCTAssertEqual(Fmt.memory(used: 12_884_901_888, total: 68_719_476_736),
                       "12.0/64 GB")
        XCTAssertEqual(Fmt.memory(used: 0, total: 17_179_869_184), "0.0/16 GB")
    }
}

/// What the header bar drops as the width it is given shrinks.
final class HeaderRightTests: XCTestCase {

    private let load = MachineLoad(cpu: 0.42, usedMemory: 25_769_803_776,
                                   totalMemory: 51_539_607_552)

    /// Paints the header pieces into a single row of the given width.
    private func drawn(width: Int, title: String) -> String {
        let pieces = Widgets.headerRight(width: width, titleEnds: 9 + title.count,
                                         clock: "22:21:54", load: load)
        var row = Array(repeating: Character(" "), count: width)
        for piece in pieces {
            let start = piece.endsAt - piece.text.count
            for (i, c) in piece.text.enumerated() where start + i >= 0 && start + i < width {
                row[start + i] = c
            }
        }
        return String(row)
    }

    func testAWideBarCarriesEverything() {
        let row = drawn(width: 120, title: "Zoom plans")
        XCTAssertTrue(row.contains("22:21:54"))
        XCTAssertTrue(row.contains("24.0/48 GB"), row)
        XCTAssertTrue(row.contains("cpu 42%"), row)
        XCTAssertTrue(row.hasSuffix("22:21:54  "), "the clock ends two in from the edge")
    }

    func testANarrowBarKeepsOnlyTheClock() {
        let row = drawn(width: 34, title: "Zoom plans")
        XCTAssertTrue(row.contains("22:21:54"))
        XCTAssertFalse(row.contains("GB"), row)
        XCTAssertFalse(row.contains("cpu"), row)
    }

    /// The title pushes the load numbers off the bar before it is itself cut.
    func testALongTitleWins() {
        let short = drawn(width: 100, title: "Maps")
        let long = drawn(width: 100, title: String(repeating: "x", count: 60))
        XCTAssertTrue(short.contains("cpu 42%"))
        XCTAssertFalse(long.contains("cpu 42%"), long)
    }

    func testNoReadingMeansNoNumbers() {
        let pieces = Widgets.headerRight(width: 120, titleEnds: 20, clock: "22:21:54",
                                         load: MachineLoad(cpu: nil, usedMemory: 0,
                                                           totalMemory: 0))
        XCTAssertEqual(pieces.count, 1)
    }
}
