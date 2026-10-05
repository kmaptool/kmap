import XCTest

@testable import kmap

#if !os(Windows)
final class ChildProcessStopAllTests: XCTestCase {
    /// A kmap made to leave stops the tools it runs: they are in groups of their own.
    func testEveryTrackedToolIsStopped() throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/sleep")
        tool.arguments = ["30"]
        try tool.run()
        ChildProcess.track(tool)
        defer { ChildProcess.untrack(tool) }
        XCTAssertTrue(tool.isRunning)
        ChildProcess.stopAll()
        XCTAssertTrue(ChildProcess.waitForExit(tool, within: 2))
    }
}
#endif
