import XCTest
@testable import kmap

/// The time-left figure for a job made of many small parts. The rate is taken over a
/// moving window, so a burst of parts landing together does not read as a fast link.
final class PaceTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: Saying nothing until there is something to say

    func testItSaysNothingBeforeTheSampleCoversAnyTime() {
        var pace = Pace()
        pace.note(done: 0, at: at(0))
        pace.note(done: 6, at: at(1.5))
        XCTAssertNil(pace.rate(at: at(1.5)))
        XCTAssertNil(pace.secondsLeft(1_400, at: at(1.5)),
                     "six tiles in a second and a half says nothing about a job of 1400")
    }

    func testItSaysNothingUntilEnoughPartsHaveFinished() {
        // Time alone is not a sample; a number of finished parts is wanted as well.
        var pace = Pace()
        pace.note(done: 0, at: at(0))
        pace.note(done: 2, at: at(30))
        XCTAssertNil(pace.secondsLeft(1_000, at: at(30)))
    }

    func testOnceTheWindowHoldsARealSampleItAnswers() {
        var pace = Pace()
        for second in stride(from: 0, through: 40, by: 2) {
            pace.note(done: second / 2, at: at(TimeInterval(second)))
        }
        // Twenty tiles in forty seconds is one every two seconds; nine hundred left is
        // half an hour.
        let left = try? XCTUnwrap(pace.secondsLeft(900, at: at(40)))
        XCTAssertEqual(left ?? 0, 1_800, accuracy: 60)
    }

    // MARK: The bug it was written for

    func testABurstDoesNotConvinceItTheJobIsNearlyDone() {
        // A batch lands, then nothing, then the next: the rate is batches over the time
        // between them, not a batch over the instant it arrived in.
        var pace = Pace()
        var done = 0
        var now: TimeInterval = 0
        for _ in 0..<12 {
            // Nothing for twelve seconds, then six at once.
            for tick in stride(from: 0.0, to: 12.0, by: 0.3) {
                pace.note(done: done, at: at(now + tick))
            }
            now += 12
            done += 6
            pace.note(done: done, at: at(now))
        }
        let left = try? XCTUnwrap(pace.secondsLeft(1_400, at: at(now)))
        // Six every twelve seconds is one every two, so fourteen hundred is about
        // forty-six minutes; what is checked is the order of magnitude.
        XCTAssertGreaterThan(left ?? 0, 1_500, "a burst still says the job is nearly done")
        XCTAssertEqual(left ?? 0, 2_800, accuracy: 700,
                       "the window edge falls between batches, which is worth a batch either way")
    }

    func testItFollowsALinkThatSpeedsUp() {
        // An average since the start would carry the slow beginning for the rest of the run.
        var pace = Pace()
        var done = 0
        for second in stride(from: 0, through: 60, by: 3) {           // one every 3s
            pace.note(done: done, at: at(TimeInterval(second)))
            done += 1
        }
        let slow = pace.secondsLeft(600, at: at(60)) ?? 0
        for tenth in stride(from: 60.5, through: 130, by: 0.5) {      // one every half second
            done += 1
            pace.note(done: done, at: at(tenth))
        }
        let fast = pace.secondsLeft(600, at: at(130)) ?? 0
        XCTAssertLessThan(fast, slow / 3, "\(fast) against \(slow)")
    }

    // MARK: Arithmetic that has to hold

    func testTheLastPartClaimsNoTimeAtAll() {
        var pace = Pace()
        for second in stride(from: 0, through: 40, by: 1) {
            pace.note(done: second, at: at(TimeInterval(second)))
        }
        XCTAssertNil(pace.secondsLeft(0, at: at(40)))
    }

    func testAStalledJobSaysNothingRatherThanForever() {
        // Nothing finished for a minute: a rate of zero gives no answer rather than infinity.
        var pace = Pace()
        for second in stride(from: 0, through: 90, by: 1) {
            pace.note(done: 40, at: at(TimeInterval(second)))
        }
        XCTAssertNil(pace.secondsLeft(500, at: at(90)))
    }

    func testTheWindowKeepsTheSampleFromGrowingWithoutEnd() {
        // Sampled five times a second for an hour, which is what the display does.
        var pace = Pace()
        for tick in stride(from: 0.0, through: 3_600.0, by: 0.2) {
            pace.note(done: Int(tick / 2), at: at(tick))
        }
        // The answer still comes from the last minute, not from the whole hour.
        let left = try? XCTUnwrap(pace.secondsLeft(1_000, at: at(3_600)))
        XCTAssertEqual(left ?? 0, 2_000, accuracy: 100)
    }
}
