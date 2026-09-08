import XCTest
@testable import kmap

/// The shape every `--json` run answers in, whatever the command: one JSON object per
/// line on stdout and nothing anywhere else; `start` first, `end` last, `seq` counting
/// from 1 without gaps; a non-zero exit explained by an `error` event or answered by a
/// `result` the caller can read the verdict from.
final class CLIJSONEnvelopeTests: XCTestCase {

    override func tearDown() {
        CLILog.proseSuppressed = false
        super.tearDown()
    }

    private struct Run {
        let code: Int32
        let events: [[String: Any]]
        let error: String
    }

    private func run(_ arguments: [String]) async throws -> Run {
        var code: Int32 = 0
        let previous = CLILog.proseSuppressed
        defer { CLILog.proseSuppressed = previous }
        let collected = try await withCapturedOutput {
            code = await CLI.run(arguments)
        }
        let events = try collected.out.split(separator: "\n").filter { !$0.isEmpty }
            .map { line -> [String: Any] in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try XCTUnwrap(object as? [String: Any], String(line))
            }
        return Run(code: code, events: events, error: collected.error)
    }

    /// CLILog.capture for an async body.
    private func withCapturedOutput(_ body: () async -> Void) async throws
        -> (out: String, error: String) {
        // CLILog's sink is static; swap it by hand around the await.
        var out = "", errors = ""
        CLILog.sinkForTests = { text, isError in
            if isError { errors += text } else { out += text }
        }
        defer { CLILog.sinkForTests = nil }
        await body()
        return (out, errors)
    }

    private func assertEnvelope(_ run: Run, command: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.error, "", "stderr must stay empty under --json", file: file, line: line)
        guard let first = run.events.first, let last = run.events.last else {
            XCTFail("no events at all", file: file, line: line); return
        }
        XCTAssertEqual(first["event"] as? String, "start", file: file, line: line)
        XCTAssertEqual(first["command"] as? String, command, file: file, line: line)
        XCTAssertNotNil(first["schema"], file: file, line: line)
        XCTAssertNotNil(first["version"], file: file, line: line)
        XCTAssertEqual(last["event"] as? String, "end", file: file, line: line)
        XCTAssertEqual(last["code"] as? Int, Int(run.code), file: file, line: line)
        XCTAssertEqual(last["ok"] as? Bool, run.code == 0, file: file, line: line)
        let seqs = run.events.map { $0["seq"] as? Int }
        XCTAssertEqual(seqs, (1...run.events.count).map { $0 },
                       "seq must count from 1 without gaps", file: file, line: line)
        for event in run.events {
            XCTAssertNotNil(event["at"], "every line carries a timestamp", file: file, line: line)
        }
        let names = run.events.compactMap { $0["event"] as? String }
        if run.code != 0 {
            XCTAssertTrue(names.contains("error") || names.contains("result"),
                          "a refusal must be an event, not silence", file: file, line: line)
        }
    }

    func testEveryCheapCommandKeepsTheEnvelope() async throws {
        let cases: [(command: String, arguments: [String], code: Int32)] = [
            ("--version", ["--version", "--json"], 0),
            ("styles", ["styles", "--json"], 0),
            ("profiles", ["profiles", "--json"], 0),
            ("hideable", ["hideable", "--json"], 0),
            ("frobnicate", ["frobnicate", "--json"], 2),
            ("profiles", ["profiles", "show", "Nowhere", "--json"], 2),
            ("verify", ["verify", "/nonexistent-\(UUID().uuidString).img", "--json"], 1),
        ]
        for (command, arguments, expected) in cases {
            let made = try await run(arguments)
            XCTAssertEqual(made.code, expected, arguments.joined(separator: " "))
            assertEnvelope(made, command: command)
        }
    }

    func testARefusedBuildNamesEveryProblemInOneEvent() async throws {
        let made = try await run(["build", "nowhere-at-all", "--interval=zzz", "--json"])
        XCTAssertEqual(made.code, 2)
        assertEnvelope(made, command: "build")
        // The refusal reaches the stream as data, not as suppressed prose.
        let carried = made.events.contains {
            ($0["event"] as? String) == "error" || $0["refused"] != nil
                || (($0["data"] as? [String: Any])?["refused"]) != nil
        }
        XCTAssertTrue(carried, "\(made.events)")
    }

    func testExtractTypRefusesUnderJSONInsteadOfWaitingOnStdin() async throws {
        let made = try await run(["extract-typ", "/nonexistent.img", "--json"])
        XCTAssertEqual(made.code, 2)
        let message = made.events.compactMap { $0["message"] as? String }.joined()
        XCTAssertTrue(message.contains("without --json"), message)
    }
}

/// Exit codes a script can trust without parsing: a file the command could not read at
/// all is a non-zero exit, whatever else the report says.
final class CLIExitCodeTests: XCTestCase {
    func testTypinfoOnSomethingThatIsNotAMapExitsNonZero() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-map-\(UUID().uuidString).txt")
        try "just text".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var code: Int32 = 0
        _ = CLILog.capture { code = CLI.typinfo([scratch.path]) }
        XCTAssertEqual(code, 1)
        _ = CLILog.capture { code = CLI.typinfo(["/nonexistent-\(UUID().uuidString).img"]) }
        XCTAssertEqual(code, 1)
    }
}
