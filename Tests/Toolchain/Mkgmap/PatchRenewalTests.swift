import XCTest

@testable import kmap

/// The patch rebuild shared by its callers: each gets 1 answer, and the rebuild knows
/// when its last caller has gone.
final class PatchRenewalTests: XCTestCase {
    func testTheFirstAnswerIsTheOneAndALaterOneIsDropped() async {
        let answer = MkgmapPatchRenewalAnswer()
        XCTAssertTrue(answer.give(false), "a stop came first")
        XCTAssertFalse(answer.give(true))
        let got = await withCheckedContinuation { answer.wait($0) }
        XCTAssertFalse(got, "given before the wait, answered at once")
    }

    func testAWaitIsAnsweredWhenTheAnswerComes() async {
        let answer = MkgmapPatchRenewalAnswer()
        let got = await withCheckedContinuation { continuation in
            answer.wait(continuation)
            answer.give(true)
        }
        XCTAssertTrue(got)
    }

    func testTheLastCallerToLeaveIsTold() {
        let renewal = MkgmapPatchRenewal()
        XCTAssertTrue(renewal.join())
        XCTAssertFalse(renewal.leave())
        XCTAssertTrue(renewal.leave(), "the 1 who made it, and the 1 who joined")
        XCTAssertFalse(renewal.join(), "once all have left it is being stopped")
    }
}
