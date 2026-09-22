import Foundation

/// How this run of the command line answers.
///
/// Two shapes. Text is for a person. JSON is one object per line on standard output, in
/// the order things happened, for a program driving kmap. A command prints its prose as
/// it always did and states the same answer as data through ``result(_:)``; which of the
/// two owns standard output is settled once, by ``begin(_:command:)``.
///
/// Every JSON line carries `event`, `seq` and `at`. `seq` counts from 1 without gaps, so a
/// reader can tell it lost one. New fields may appear in later versions and a reader
/// should ignore what it does not know; `schema` on the opening line says which version
/// this is.
enum CLIOutput {
    enum Shape { case text, json }

    /// The stream's contract version. Raised when a field changes meaning or goes away,
    /// never for a field that is merely added.
    static let schema = 1

    /// Exit codes a script can act on.
    enum Exit {
        /// The command ran and something went wrong.
        static let failed: Int32 = 1
        /// The command line was refused, and nothing was attempted.
        static let refused: Int32 = 2
        /// The run was cut short by the user, as a shell reports Ctrl+C.
        static let cancelled: Int32 = 130
    }

    private struct State {
        var shape: Shape = .text
        var options = CLIOptions()
        var sequence = 0
    }

    private static let state = Locked(State())

    static var isJSON: Bool { state.withLock { $0.shape == .json } }

    /// The lowest severity to report, which `--verbose` lowers.
    static var showing: LogSeverity { state.withLock { $0.options.showing } }

    /// Sets the shape for this run and, in JSON, writes the opening line.
    static func begin(_ options: CLIOptions, command: String) {
        state.withLock {
            $0.options = options
            $0.shape = options.json ? .json : .text
            $0.sequence = 0
        }
        CLILog.proseSuppressed = options.json
        guard options.json else { return }
        emit(
            "start",
            [
                "command": .string(command),
                "version": .string(Version.full),
                "schema": .int(schema)
            ]
        )
    }

    /// Writes the closing line and answers with the code the run earned, so a caller can
    /// `return CLIOutput.end(code)`.
    @discardableResult
    static func end(_ code: Int32) -> Int32 {
        if isJSON { emit("end", ["ok": .bool(code == 0), "code": .int(Int(code))]) }
        return code
    }

    // MARK: What a command says

    /// The command's answer, as data. Ignored in text, where the prose already said it.
    static func result(_ data: JSONValue) {
        guard isJSON else { return }
        emit("result", ["data": data])
    }

    /// Something went wrong. In text this is the stderr line it always was; in JSON it
    /// is an `error` event and nothing else, so the parser gets one story in one shape.
    static func failure(_ message: String, code: Int32 = Exit.failed) -> Int32 {
        CLILog.error(message)
        if isJSON { emit("error", ["message": .string(message), "code": .int(Int(code))]) }
        return code
    }

    /// The command line was wrong: a usage line, or a flag nothing answers to.
    static func refuse(_ message: String) -> Int32 {
        failure(message, code: Exit.refused)
    }

    /// Several things wrong at once: each on the error stream, and all of them in one
    /// result under `--json`, so one run reports everything wrong with it.
    static func refuse(_ lines: [String]) -> Int32 {
        for line in lines { CLILog.error(line) }
        result(["refused": .array(lines.map(JSONValue.string))])
        return Exit.refused
    }

    // MARK: What a run says as it goes

    static func log(_ event: LogEvent) {
        guard isJSON else { return }
        var fields: [String: JSONValue] = [
            "severity": .string(event.severity.name),
            "kind": .string(event.kind.rawValue),
            "text": .string(event.text)
        ]
        if let stage = event.stage { fields["stage"] = .string(stage) }
        if !event.fields.isEmpty { fields["fields"] = .object(event.fields) }
        emit("log", fields)
    }

    /// A stage changing state: pending to running, running to done.
    static func stage(_ id: String, _ status: String, title: String, detail: String) {
        guard isJSON else { return }
        var fields: [String: JSONValue] = [
            "stage": .string(id),
            "status": .string(status),
            "title": .string(title)
        ]
        if !detail.isEmpty { fields["detail"] = .string(detail) }
        emit("stage", fields)
    }

    /// How far along the run is: `overall` for the whole of it, `fraction` for the stage
    /// named, where that stage counts its own work.
    static func progress(
        stage id: String?,
        fraction: Double?,
        overall: Double,
        detail: String = ""
    ) {
        guard isJSON else { return }
        var fields: [String: JSONValue] = ["overall": .double(rounded(overall))]
        if let id { fields["stage"] = .string(id) }
        if let fraction { fields["fraction"] = .double(rounded(fraction)) }
        if !detail.isEmpty { fields["detail"] = .string(detail) }
        emit("progress", fields)
    }

    // MARK: Writing

    /// Rounds to whole percent, so a bar that has not visibly moved does not fill the
    /// stream with lines saying so.
    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func emit(_ name: String, _ fields: [String: JSONValue]) {
        // Numbered and stamped in one step, so the stream's order is the numbers' order.
        let line = state.withLock { state -> String in
            state.sequence += 1
            var object = fields
            object["event"] = .string(name)
            object["seq"] = .int(state.sequence)
            object["at"] = .string(Stamp.now())
            return JSONValue.object(object).line()
        }
        CLILog.data(line)
    }
}

/// The one time format the stream uses: RFC 3339, UTC, milliseconds.
private enum Stamp {
    /// Behind a lock: a formatter is a class with state of its own, and events are
    /// stamped from whichever thread has something to say.
    private static let formatter: Locked<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return Locked(formatter)
    }()

    static func now(_ date: Date = Date()) -> String {
        formatter.withLock { $0.string(from: date) }
    }
}
