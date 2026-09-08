import Foundation

/// How this run of the command line answers.
///
/// Two shapes. Text is for a person and is written as it always was. JSON is one object
/// per line on standard output, in the order things happened, for a program driving kmap
/// -- a graphical front end, a script, another build system. A command prints its prose
/// as it always did and states the same answer as data through ``result(_:)``; which of
/// the two owns standard output is settled here, once, by ``begin(_:command:)``.
///
/// Every JSON line carries `event`, `seq` and `at`. `seq` counts from 1 without gaps, so
/// a reader can tell it lost one. New fields may appear in later versions; a reader
/// should ignore what it does not know. `schema` on the opening line says which version
/// this is.
enum CLIOutput {
    enum Shape { case text, json }

    /// The stream's contract version. Raised when a field changes meaning or goes away,
    /// never for a field that is merely added.
    static let schema = 1

    private static let lock = NSLock()
    private static var shape: Shape = .text
    private static var options = CLIOptions()
    private static var sequence = 0

    static var isJSON: Bool {
        lock.lock(); defer { lock.unlock() }; return shape == .json
    }

    /// The lowest severity to report, which `--verbose` lowers.
    static var showing: LogSeverity {
        lock.lock(); defer { lock.unlock() }; return options.showing
    }

    /// Sets the shape for this run and, in JSON, writes the opening line.
    static func begin(_ options: CLIOptions, command: String) {
        lock.lock()
        Self.options = options
        shape = options.json ? .json : .text
        sequence = 0
        lock.unlock()
        // Under --json standard output is the stream, and the prose is not printed.
        CLILog.proseSuppressed = options.json
        guard options.json else { return }
        emit("start", ["command": .string(command),
                       "version": .string(Version.full),
                       "schema": .int(schema)])
    }

    /// Writes the closing line and answers with the code the run earned, so a caller can
    /// `return CLIOutput.end(code)`.
    @discardableResult
    static func end(_ code: Int32) -> Int32 {
        if isJSON { emit("end", ["ok": .bool(code == 0), "code": .int(Int(code))]) }
        return code
    }

    // MARK: What a command says

    /// The command's answer, as data. Ignored when the answer is text, where the same
    /// facts are in the prose the command printed.
    static func result(_ data: JSONValue) {
        guard isJSON else { return }
        emit("result", ["data": data])
    }

    /// Something went wrong. In text this is the stderr line it always was; in JSON it
    /// is an `error` event and nothing else — the parser gets one story, in one shape.
    static func failure(_ message: String, code: Int32 = 1) -> Int32 {
        CLILog.error(message)
        if isJSON { emit("error", ["message": .string(message), "code": .int(Int(code))]) }
        return code
    }

    // MARK: What a run says as it goes

    static func log(_ event: LogEvent) {
        guard isJSON else { return }
        var fields: [String: JSONValue] = [
            "severity": .string(event.severity.name),
            "kind": .string(event.kind.rawValue),
            "text": .string(event.text),
        ]
        if let stage = event.stage { fields["stage"] = .string(stage) }
        if !event.fields.isEmpty { fields["fields"] = .object(event.fields) }
        emit("log", fields)
    }

    /// A stage changing state: pending to running, running to done.
    static func stage(_ id: String, _ status: String, title: String, detail: String) {
        guard isJSON else { return }
        var fields: [String: JSONValue] = ["stage": .string(id),
                                           "status": .string(status),
                                           "title": .string(title)]
        if !detail.isEmpty { fields["detail"] = .string(detail) }
        emit("stage", fields)
    }

    /// How far along the run is: `overall` for the whole of it, `fraction` for the stage
    /// named, where that stage counts its own work.
    static func progress(stage id: String?, fraction: Double?, overall: Double,
                         detail: String = "") {
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
        lock.lock()
        sequence += 1
        var object = fields
        object["event"] = .string(name)
        object["seq"] = .int(sequence)
        object["at"] = .string(Stamp.now())
        let line = JSONValue.object(object).line()
        lock.unlock()
        CLILog.data(line)
    }
}

/// The one time format the stream uses: RFC 3339, UTC, milliseconds.
private enum Stamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func now(_ date: Date = Date()) -> String { formatter.string(from: date) }
}
