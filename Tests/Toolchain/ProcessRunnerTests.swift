import XCTest
@testable import kmap

/// Running mkgmap. Every long command kmap runs goes through here, and the build reads
/// the reported result rather than the tool's own words.
final class ProcessRunnerTests: XCTestCase {

    private func collect(_ executable: String, _ arguments: [String],
                         allowFailure: Bool = false) async throws
    -> (result: ProcessRunner.Result, lines: [String]) {
        let lock = NSLock()
        var lines: [String] = []
        let result = try await ProcessRunner().run(executable, arguments,
                                                   allowFailure: allowFailure) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        return (result, lines)
    }

    func testOutputArrivesLineByLineAndTheExitCodeIsReported() async throws {
        let (result, lines) = try await collect(TestShell.path, TestShell.arguments(.twoLines))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(lines, ["one", "two"])
    }

    func testWhatIsPrintedWithoutATrailingNewlineIsNotLost() async throws {
        // mkgmap's last line before it exits often arrives without one.
        let (_, lines) = try await collect(TestShell.path, TestShell.arguments(.withoutTrailingNewline))
        XCTAssertEqual(lines, ["no newline here"])
    }

    func testLinesEndedTheWindowsWayAreStillLines() async throws {
        // Swift counts "\r\n" as one Character, so `firstIndex(of: "\n")` finds none of
        // them and the whole run arrives as a single line.
        let (_, lines) = try await collect(TestShell.path,
                                           TestShell.arguments(.twoLinesWithCarriageReturns))
        XCTAssertEqual(lines, ["one", "two"])
    }

    func testStandardErrorIsGatheredWithStandardOutput() async throws {
        // Java writes its failures to stderr; reading only stdout leaves an exit code
        // with nothing to explain it.
        let (_, lines) = try await collect(TestShell.path, TestShell.arguments(.toBothStreams))
        XCTAssertEqual(Set(lines), ["out", "err"])
    }

    func testANonZeroExitIsThrownWithTheLastLinesForContext() async throws {
        do {
            _ = try await collect(TestShell.path, TestShell.arguments(.failWithReason))
            XCTFail("a failing command came back as success")
        } catch let error as ProcessRunner.RunError {
            guard case .failed(_, let code, let tail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(tail.contains("the reason"), "\(tail)")
            // The message a person reads carries both.
            XCTAssertTrue(error.errorDescription?.contains("3") ?? false)
            XCTAssertTrue(error.errorDescription?.contains("the reason") ?? false)
        }
    }

    func testAFailureCanBeAllowedWhenTheCallerMeansToReadTheCode() async throws {
        let (result, _) = try await collect(TestShell.path, TestShell.arguments(.exitSeven), allowFailure: true)
        XCTAssertEqual(result.exitCode, 7)
    }

    func testSomethingThatIsNotThereFailsToLaunchRatherThanHanging() async {
        do {
            _ = try await collect(TestShell.nowhere, [])
            XCTFail("launched something that does not exist")
        } catch let error as ProcessRunner.RunError {
            guard case .launchFailed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTheEnvironmentIsAddedToTheOneKmapHasRatherThanReplacingIt() async throws {
        // Java needs PATH and HOME to work at all; handing it only JAVA_OPTS would break it.
        let (_, lines) = try await collect(TestShell.path,
                                           TestShell.arguments(.reportEnvironment))
        XCTAssertEqual(lines.first, "unset")

        let lock = NSLock()
        var withEnv: [String] = []
        _ = try await ProcessRunner().run(
            TestShell.path, TestShell.arguments(.reportEnvironment),
            environment: ["KMAP_TEST_VALUE": "here"]) { line in
                lock.lock(); withEnv.append(line); lock.unlock()
            }
        XCTAssertEqual(withEnv, ["here", "path-is-set"])
    }

    func testTheWorkingDirectoryIsWhereTheCallerSaysItIs() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = NSLock()
        var lines: [String] = []
        _ = try await ProcessRunner().run(TestShell.path,
                                          TestShell.arguments(.printWorkingDirectory),
                                          cwd: directory) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        // Compared by what the path resolves to: /tmp is a link to /private/tmp here.
        XCTAssertEqual(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       directory.resolvingSymlinksInPath().path)
    }

    func testAChildDoesNotInheritTheTerminal() async throws {
        // Left alone the child inherits kmap's own stdin, which is the terminal in raw
        // mode, and a tool that asks something would swallow keystrokes and wait.
        let (_, lines) = try await collect(TestShell.path, TestShell.arguments(.echoWhatWasTyped))
        XCTAssertEqual(lines, ["got:"])
    }

    func testCancellingStopsALongCommand() async throws {
        let runner = ProcessRunner()
        let started = Date()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            runner.cancel()
        }
        do {
            _ = try await runner.run(TestShell.path, TestShell.arguments(.sleep)) { _ in }
            XCTFail("the command was not stopped")
        } catch let error as ProcessRunner.RunError {
            guard case .cancelled = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}
