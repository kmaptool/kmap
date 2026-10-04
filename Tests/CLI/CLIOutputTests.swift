import XCTest

@testable import kmap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        let (rest, _) = CLIOptions.take(from: [
            "build", "austria", "--parts=2",
            "--verbose"
        ])
        XCTAssertEqual(rest, ["build", "austria", "--parts=2"])
    }

    func testVerboseLowersWhatIsShown() {
        XCTAssertEqual(CLIOptions().showing, .info)
        XCTAssertEqual(CLIOptions(json: false, verbose: true).showing, .debug)
    }

    // MARK: Errors in their own words

    func testAnErrorIsReportedInTheWordsWrittenForIt() {
        XCTAssertEqual(CLIOutput.said(GeoTIFF.Trouble.notTIFF), "not a TIFF file")
        XCTAssertEqual(
            CLIOutput.said(ViewfinderDEM.Trouble.notCovered("N44E034")),
            "N44E034 is outside every Viewfinder zone"
        )
    }

    func testASystemErrorIsNotDumpedWithItsAddress() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).pbf")
        do {
            _ = try Data(contentsOf: missing)
            XCTFail("the file does not exist")
        } catch {
            let said = CLIOutput.said(error)
            XCTAssertFalse(said.contains("0x"), said)
            XCTAssertFalse(said.contains("UserInfo"), said)
            XCTAssertFalse(said.isEmpty)
        }
    }

    func testANetworkOrPOSIXErrorIsReportedInItsWords() {
        let offline = CLIOutput.said(URLError(.notConnectedToInternet))
        XCTAssertFalse(offline.contains("URLError(") || offline.contains("_nsError"), offline)
        XCTAssertFalse(offline.contains("0x"), offline)
        XCTAssertFalse(offline.isEmpty)
        let missing = CLIOutput.said(POSIXError(.ENOENT))
        XCTAssertFalse(missing.contains("POSIXError("), missing)
        XCTAssertFalse(missing.isEmpty)
        // One of kmap's own, with no words written, still says which case it is.
        enum Broken: Error { case seam }
        XCTAssertEqual(CLIOutput.said(Broken.seam), "seam")
    }

    func testASystemErrorKeepsTheFileOrAddressItWasAbout() {
        let missing = CLIOutput.said(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/maps/x.osm.pbf"]))
        XCTAssertTrue(missing.contains("/maps/x.osm.pbf"), missing)
        XCTAssertFalse(missing.contains("UserInfo"), missing)
        let address = URL(string: "https://download.geofabrik.de/x.osm.pbf")!
        let offline = CLIOutput.said(
            URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: address])
        )
        XCTAssertTrue(offline.contains(address.absoluteString), offline)
        // Said once, where the words name it already.
        let named = CLIOutput.said(
            CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "x", NSLocalizedDescriptionKey: "x is gone"])
        )
        XCTAssertEqual(named, "x is gone")
    }

    func testAFileAddressIsNamedByItsPathAndADecodingErrorKeepsItsDetail() {
        let file = URL(fileURLWithPath: "/Users/Кирилл/maps/x.osm.pbf")
        let gone = CLIOutput.said(CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: file]))
        XCTAssertTrue(gone.contains("/Users/Кирилл/maps/x.osm.pbf"), gone)
        XCTAssertFalse(gone.contains("%D0"), gone)
        struct Settings: Decodable { let heap: Int }
        do {
            _ = try JSONDecoder().decode(Settings.self, from: Data(#"{"heap": "lots"}"#.utf8))
            XCTFail("not a number")
        } catch {
            XCTAssertTrue(CLIOutput.said(error).contains("heap"), CLIOutput.said(error))
        }
    }

    // MARK: Stages in JSON

    func testJSONReportsAStageOnlyForward() {
        // A held split is running all along: the stream never sees it go back.
        XCTAssertEqual(CLI.reported(.pending, after: nil, ended: false), .pending)
        XCTAssertEqual(CLI.reported(.running, after: .pending, ended: false), .running)
        XCTAssertNil(CLI.reported(.running, after: .running, ended: false), "said once")
        XCTAssertEqual(CLI.reported(.done, after: .running, ended: false), .done)
        XCTAssertEqual(CLI.reported(.failed, after: .running, ended: true), .failed)
        XCTAssertEqual(CLI.reported(.skipped, after: .pending, ended: false), .skipped)
        // Put back to not started while the build goes on: not news to a reader.
        XCTAssertNil(CLI.reported(.pending, after: .running, ended: false))
        XCTAssertNil(CLI.reported(.pending, after: .pending, ended: true))
    }

    func testAStageHeldWhenTheBuildStoppedEndsFailedInJSON() {
        // The screen shows it not started; a reader who saw it running is told it ended.
        XCTAssertEqual(CLI.reported(.pending, after: .running, ended: true), .failed)
    }

    func testAStageIsHeadedWhenItStartsAndAgainWhenItRunsAnew() {
        XCTAssertFalse(CLI.heads(.pending, seen: nil, before: false))
        XCTAssertTrue(CLI.heads(.running, seen: .pending, before: false))
        XCTAssertTrue(CLI.heads(.done, seen: .pending, before: false), "began and ended between 2 polls")
        XCTAssertFalse(CLI.heads(.running, seen: .running, before: true))
        XCTAssertFalse(CLI.heads(.done, seen: .running, before: true))
        // A re-split: the split runs again after it was done.
        XCTAssertTrue(CLI.heads(.running, seen: .done, before: true))
        XCTAssertTrue(CLI.heads(.running, seen: .failed, before: true))
        // Put back while a damaged extract downloads again, then at work again.
        XCTAssertTrue(CLI.heads(.running, seen: .pending, before: true))
    }

    // MARK: A long log

    func testTheLogKeepsPrintingOnceItsRingDropsTheOldestLines() {
        // The ring keeps the last 3 here, the last 4000 in a build: printed by number, the
        // log goes on printing once the ring is full.
        let log = Log(limit: 3)
        var printer = CLI.LogPrinter()
        for n in 1...3 { log.append("line \(n)") }
        let first = CLILog.capture { printer.drain(log) }.out
        for n in 4...5 { log.append("line \(n)") }
        let second = CLILog.capture { printer.drain(log) }.out
        let third = CLILog.capture { printer.drain(log) }.out
        XCTAssertTrue(first.contains("line 1") && first.contains("line 3"), first)
        XCTAssertTrue(second.contains("line 4") && second.contains("line 5"), second)
        XCTAssertFalse(second.contains("line 3"), "printed once")
        XCTAssertEqual(third, "", "nothing new")
    }

    // MARK: Stage headings among the log lines

    func testAHeadingStandsAboveTheLinesWrittenAfterItsStageBegan() {
        let start = Date(timeIntervalSince1970: 1000)
        func line(_ text: String, _ seconds: Double) -> LogEvent {
            LogEvent(text: text, at: start.addingTimeInterval(seconds))
        }
        let lines = [line("region", 0.1), line("cached", 1.2), line("elevation data", 1.5), line("compiled", 9)]
        let items = CLI.LogPrinter.interleaved(
            lines,
            marks: [
                (start.addingTimeInterval(8), .heading("── Compile map")),
                (start.addingTimeInterval(1), .heading("── Download OSM extract")),
                (start.addingTimeInterval(1.4), .heading("── Download elevation")),
                (start.addingTimeInterval(20), .heading("── Write output"))
            ]
        )
        let said = items.map(Self.said)
        XCTAssertEqual(
            said,
            [
                "region", "── Download OSM extract", "cached", "── Download elevation", "elevation data",
                "── Compile map", "compiled", "── Write output"
            ]
        )
    }

    func testHeadingsWithNoLinesStillPrint() {
        let items = CLI.LogPrinter.interleaved([], marks: [(Date(), .heading("── Split into tiles"))])
        XCTAssertEqual(items.count, 1)
    }

    private static func said(_ item: CLI.LogPrinter.Item) -> String {
        switch item {
        case .heading(let text): return text
        case .stage(let id, let status, _): return "\(id.rawValue) \(status.rawValue)"
        case .line(let line): return line.text
        }
    }

    private func stage(
        _ id: BuildPipeline.StageID,
        _ status: BuildPipeline.StageStatus,
        from started: Date?,
        for seconds: Double = 0
    ) -> BuildPipeline.Stage {
        var stage = BuildPipeline.Stage(id: id)
        stage.status = status
        stage.startedAt = started
        stage.seconds = seconds
        return stage
    }

    func testAStageThatEndsAndOneThatBeginsBetween2PollsAreToldInTheirOrder() {
        // Preflight logs its closing line and ends, the data update begins and logs: the
        // stream says so in that order, though both changes are read at once.
        let start = Date(timeIntervalSince1970: 1000)
        var news = CLI.StageNews()
        _ = news.marks(
            [stage(.preflight, .running, from: start)],
            ended: false,
            stopped: "failed",
            polled: start.addingTimeInterval(0.1)
        )
        let polled = start.addingTimeInterval(0.35)
        let marks = news.marks(
            [
                stage(.preflight, .done, from: start, for: 0.2),
                stage(.dataUpdate, .running, from: start.addingTimeInterval(0.25))
            ],
            ended: false,
            stopped: "failed",
            polled: polled
        )
        let lines = [
            LogEvent(text: "tools found", at: start.addingTimeInterval(0.15)),
            LogEvent(text: "checking data", at: start.addingTimeInterval(0.3))
        ]
        let said = CLI.LogPrinter.interleaved(lines, marks: marks).map(Self.said)
        XCTAssertEqual(
            said,
            [
                "tools found", "preflight done", "── \(BuildPipeline.StageID.dataUpdate.title)", "dataUpdate running",
                "checking data"
            ]
        )
    }

    func testALineWrittenAfterThePollWaitsForTheNext() {
        // Counted by number, not by time: a clock set back holds nothing up.
        var printer = CLI.LogPrinter()
        let log = Log()
        log.send(LogEvent(text: "early", at: Date()))
        let last = log.lastSeq
        log.send(LogEvent(text: "late", at: Date().addingTimeInterval(-3600)))
        let first = CLILog.capture { printer.drain(log.snapshot(), through: last) }.out
        let second = CLILog.capture { printer.drain(log.snapshot(), through: log.lastSeq) }.out
        XCTAssertTrue(first.contains("early") && !first.contains("late"), first)
        XCTAssertTrue(second.contains("late") && !second.contains("early"), second)
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
            CLIOutput.log(
                LogEvent(
                    text: "7 tile(s)",
                    severity: .info,
                    kind: .ok,
                    stage: "split",
                    fields: ["tiles": 7]
                )
            )
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
        XCTAssertFalse(
            gate.speaks(
                stage: "split",
                fraction: nil,
                overall: 0.6,
                detail: "reading ways"
            )
        )
    }

    func testADetailChangeAloneSpeaks() {
        // Verifying a cached extract and splitting into tiles have no percentage;
        // their detail line is the only sign of life, and the stream must carry it.
        var gate = CLI.ProgressGate()
        _ = gate.speaks(
            stage: "download",
            fraction: nil,
            overall: 0.09,
            detail: "verifying cached copy · 10%"
        )
        XCTAssertTrue(
            gate.speaks(
                stage: "download",
                fraction: nil,
                overall: 0.09,
                detail: "verifying cached copy · 20%"
            )
        )
    }

    func testTheWholeBuildsBarMovingSpeaks() {
        var gate = CLI.ProgressGate()
        _ = gate.speaks(stage: "download", fraction: nil, overall: 0.09, detail: "starting")
        XCTAssertTrue(
            gate.speaks(
                stage: "download",
                fraction: nil,
                overall: 0.24,
                detail: "starting"
            )
        )
    }
}
