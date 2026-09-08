import XCTest
@testable import kmap

/// The two shapes the command line answers in, and the flags that choose between them.
final class CLIOptionsTests: XCTestCase {

    func testTheSharedFlagsAreTakenOutOfTheArguments() {
        // `kmap regions --json austria` searches for austria, not for "--json".
        let (rest, options) = CLIOptions.take(from: ["regions", "--json", "austria"])
        XCTAssertEqual(rest, ["regions", "austria"])
        XCTAssertTrue(options.json)
        XCTAssertFalse(options.verbose)
    }

    func testACommandsOwnFlagsAreLeftAlone() {
        let (rest, _) = CLIOptions.take(from: ["build", "austria", "--parts=2",
                                              "--verbose"])
        XCTAssertEqual(rest, ["build", "austria", "--parts=2"])
    }

    func testVerboseLowersWhatIsShown() {
        XCTAssertEqual(CLIOptions().showing, .info)
        XCTAssertEqual(CLIOptions(json: false, verbose: true).showing, .debug)
    }
}

/// The JSON stream: one object per line, in the order things happened.
final class CLIOutputTests: XCTestCase {

    override func tearDown() {
        CLIOutput.begin(CLIOptions(), command: "test")
        super.tearDown()
    }

    /// Runs `body` with the JSON shape and returns the objects written to stdout.
    private func stream(_ body: () -> Void) throws -> [[String: Any]] {
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(json: true, verbose: false), command: "test")
            body()
            CLIOutput.end(0)
        }
        return try captured.out.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [String: Any])
        }
    }

    func testTheStreamOpensAndClosesAndNumbersEveryLine() throws {
        let lines = try stream {
            CLIOutput.result(["styles": .array([])])
        }
        XCTAssertEqual(lines.map { $0["event"] as? String }, ["start", "result", "end"])
        XCTAssertEqual(lines.map { $0["seq"] as? Int }, [1, 2, 3])
        XCTAssertEqual(lines[0]["schema"] as? Int, CLIOutput.schema)
        XCTAssertEqual(lines[0]["command"] as? String, "test")
        XCTAssertEqual(lines[2]["ok"] as? Bool, true)
    }

    func testTheProseIsNotPrintedAtAllUnderJSON() {
        // Whoever asked for JSON is parsing: the stream carries everything, so the
        // sentences print nowhere — not even on standard error.
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(json: true, verbose: false), command: "test")
            CLILog.line("a table a person reads")
            CLIOutput.result(["ok": true])
        }
        XCTAssertFalse(captured.out.contains("a table a person reads"))
        XCTAssertEqual(captured.error, "")
        XCTAssertTrue(captured.out.contains("\"event\":\"result\""))
    }

    func testTextIsWhereItAlwaysWasWhenTheFlagIsAbsent() {
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(), command: "test")
            CLILog.line("a table a person reads")
            CLIOutput.result(["ok": true])
        }
        XCTAssertEqual(captured.out, "a table a person reads\n")
        XCTAssertEqual(captured.error, "")
    }

    func testAFailureIsOnlyAnEventUnderJSON() throws {
        var code: Int32 = 0
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(json: true, verbose: false), command: "test")
            code = CLIOutput.failure("no region with id \"nowhere\"", code: 2)
        }
        XCTAssertEqual(code, 2)
        XCTAssertEqual(captured.error, "")
        XCTAssertTrue(captured.out.contains("\"event\":\"error\""))
    }

    func testAFailureIsStillASentenceWithoutJSON() throws {
        var code: Int32 = 0
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(), command: "test")
            code = CLIOutput.failure("no region with id \"nowhere\"", code: 2)
        }
        XCTAssertEqual(code, 2)
        XCTAssertTrue(captured.error.contains("no region with id"))
    }

    func testALogEventCarriesItsSeverityKindStageAndFields() throws {
        let lines = try stream {
            CLIOutput.log(LogEvent(text: "7 tile(s)", severity: .info, kind: .ok,
                                   stage: "split", fields: ["tiles": 7]))
        }
        let event = lines[1]
        XCTAssertEqual(event["event"] as? String, "log")
        XCTAssertEqual(event["severity"] as? String, "info")
        XCTAssertEqual(event["kind"] as? String, "ok")
        XCTAssertEqual(event["stage"] as? String, "split")
        XCTAssertEqual((event["fields"] as? [String: Any])?["tiles"] as? Int, 7)
    }

    func testProgressIsRoundedToWholePercent() throws {
        let lines = try stream {
            CLIOutput.progress(stage: "split", fraction: 0.123456, overall: 0.456789)
        }
        XCTAssertEqual(lines[1]["fraction"] as? Double, 0.12)
        XCTAssertEqual(lines[1]["overall"] as? Double, 0.46)
    }

    func testNothingIsWrittenToTheStreamWhenTheAnswerIsText() {
        let captured = CLILog.capture {
            CLIOutput.begin(CLIOptions(), command: "test")
            CLIOutput.log(LogEvent(text: "compiling"))
            CLIOutput.stage("split", "running", title: "Splitting", detail: "")
            CLIOutput.progress(stage: "split", fraction: 0.5, overall: 0.5)
            CLIOutput.result(["ok": true])
        }
        XCTAssertEqual(captured.out, "")
    }
}

/// The values a payload is built from, which have to render the same way every time.
final class JSONValueTests: XCTestCase {

    func testKeysAreSortedSoTheSameValueIsAlwaysTheSameBytes() {
        let value: JSONValue = ["b": 2, "a": 1, "c": ["z": true, "y": nil]]
        XCTAssertEqual(value.line(), #"{"a":1,"b":2,"c":{"y":null,"z":true}}"#)
    }

    func testSlashesAreNotEscapedSoAPathReadsAsAPath() {
        XCTAssertEqual(JSONValue.string("/Users/x/map.img").line(), #""/Users/x/map.img""#)
    }

    func testAnOptionalBecomesNullRatherThanGoingMissing() {
        XCTAssertEqual(JSONValue.of(nil as String?), .null)
        XCTAssertEqual(JSONValue.of("here"), .string("here"))
        // An infinite double has no JSON spelling, so it is null too.
        XCTAssertEqual(JSONValue.of(Double.infinity), .null)
    }
}

/// Which polls of a running stage earn a progress event in the JSON stream.
final class ProgressGateTests: XCTestCase {

    func testAStageBarMovingByAPercentSpeaks() {
        var gate = CLI.ProgressGate()
        XCTAssertTrue(gate.speaks(stage: "compile", fraction: 0, overall: 0.7, detail: "0/13"))
        XCTAssertTrue(gate.speaks(stage: "compile", fraction: 0.02, overall: 0.7, detail: "0/13"))
    }

    func testAnUnchangedPollStaysSilent() {
        var gate = CLI.ProgressGate()
        _ = gate.speaks(stage: "split", fraction: nil, overall: 0.6, detail: "reading ways")
        XCTAssertFalse(gate.speaks(stage: "split", fraction: nil, overall: 0.6,
                                   detail: "reading ways"))
    }

    func testADetailChangeAloneSpeaks() {
        // Verifying a cached extract and splitting into tiles have no percentage;
        // their detail line is the only sign of life, and the stream must carry it.
        var gate = CLI.ProgressGate()
        _ = gate.speaks(stage: "download", fraction: nil, overall: 0.09,
                        detail: "verifying cached copy · 10%")
        XCTAssertTrue(gate.speaks(stage: "download", fraction: nil, overall: 0.09,
                                  detail: "verifying cached copy · 20%"))
    }

    func testTheWholeBuildsBarMovingSpeaks() {
        var gate = CLI.ProgressGate()
        _ = gate.speaks(stage: "download", fraction: nil, overall: 0.09, detail: "starting")
        XCTAssertTrue(gate.speaks(stage: "download", fraction: nil, overall: 0.24,
                                  detail: "starting"))
    }
}
