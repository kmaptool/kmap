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

    private func scratchFile() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    /// The pid a script wrote, once it has.
    private func pid(in file: URL) -> pid_t? {
        for _ in 0..<250 {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            usleep(20_000)
        }
        return nil
    }

    /// Gone, or dead and waiting to be reaped: in a container whose first process reaps
    /// late, a killed orphan stays a zombie a while, which `kill(pid, 0)` still finds.
    private func isGone(_ pid: pid_t, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            #if os(Linux)
            if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let close = stat.lastIndex(of: ")"),
                stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
            {
                return true
            }
            #endif
            usleep(20_000)
        }
        return false
    }

    /// What a tool forks is in its group, and goes with it: pyhgtmap's workers would
    /// otherwise outlive kmap.
    func testWhatAToolForkedIsStoppedWithIt() throws {
        let file = scratchFile()
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/sh")
        tool.arguments = ["-c", "sleep 30 & echo $! > '\(file.path)'; wait"]
        try tool.run()
        ChildProcess.track(tool)
        defer { ChildProcess.untrack(tool) }
        let worker = try XCTUnwrap(pid(in: file))

        ChildProcess.stopAll(grace: 1)

        XCTAssertTrue(ChildProcess.waitForExit(tool, within: 2))
        XCTAssertTrue(isGone(worker, within: 2), "the forked worker")
    }

    /// A tool tracked alone that ends in the grace and is untracked is still let go
    /// alone: what it forked finishes, as dpkg under apt must.
    func testAToolTrackedAloneKeepsItsGroupWhenItEndsInTheGrace() throws {
        let file = scratchFile()
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/sh")
        tool.arguments = ["-c", "trap 'exit 0' TERM; sleep 30 & echo $! > '\(file.path)'; wait"]
        // As the runner does once the tool has ended, before `stopAll` sees it end.
        #if !os(Linux)
        let untracked = expectation(description: "untracked")
        #endif
        tool.terminationHandler = { ended in
            ChildProcess.untrack(ended)
            #if !os(Linux)
            untracked.fulfill()
            #endif
        }
        try tool.run()
        ChildProcess.track(tool, alone: true)
        let worker = try XCTUnwrap(pid(in: file))
        defer { kill(worker, SIGKILL) }

        ChildProcess.stopAll(grace: 1.5)
        #if os(Linux)
        // Foundation here hears of an end by a socket the worker holds too, so not while the
        // worker lives: the tool's end is read from the kernel.
        XCTAssertTrue(isGone(tool.processIdentifier, within: 2), "the tool")
        #else
        wait(for: [untracked], timeout: 2)
        XCTAssertFalse(tool.isRunning)
        #endif
        XCTAssertFalse(isGone(worker, within: 0.3), "the worker it forked")
    }

    /// A cancelled tool that shrugs off the polite ask stays tracked until it is killed,
    /// so a kmap leaving in the meantime takes it along.
    func testACancelledToolStaysTrackedUntilItIsKilled() async throws {
        let file = scratchFile()
        let runner = ProcessRunner()
        let run = Task {
            try? await runner.run("/bin/sh", ["-c", "trap '' TERM; echo $$ > '\(file.path)'; sleep 30"]) { _ in }
        }
        let tool = try XCTUnwrap(pid(in: file))
        runner.cancel()
        _ = await run.value
        XCTAssertEqual(kill(tool, 0), 0, "it ignores the ask")

        ChildProcess.stopAll(grace: 0)

        XCTAssertTrue(isGone(tool, within: 1.5), "killed on the way out, before the runner's own grace")
    }

    /// Once kmap is leaving, no tool starts and a tool started anyway is killed: the list
    /// `stopAll` took is behind it.
    func testOnceLeavingNoToolStartsAndALateOneIsKilled() async throws {
        ChildProcess.leave(grace: 0)
        defer { ChildProcess.stayForTests() }
        do {
            _ = try await ProcessRunner().run("/bin/sh", ["-c", "true"]) { _ in }
            XCTFail("a tool started while leaving")
        } catch ProcessRunner.RunError.cancelled {}
        XCTAssertNil(ProcessProbe.exitCode("/bin/sh", ["-c", "true"]), "a probe neither")

        let late = Process()
        late.executableURL = URL(fileURLWithPath: "/bin/sleep")
        late.arguments = ["30"]
        try late.run()
        ChildProcess.track(late)
        defer { ChildProcess.untrack(late) }
        XCTAssertTrue(ChildProcess.waitForExit(late, within: 2))
    }
}
#endif
