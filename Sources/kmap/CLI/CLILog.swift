import Foundation

/// The command line's output.
///
/// Commands write through this rather than `print` so results and diagnostics stay on
/// separate streams, and so a test or an embedding program can capture both. Text is
/// written as given: the command line is a scripting surface, and its output is
/// compared byte for byte.
///
/// Where the prose goes is decided once per run. Normally it is standard output. Under
/// `--json` the prose is not printed at all: whoever asked for JSON is parsing, and the
/// stream carries everything the prose would have said — results, log lines and errors —
/// as events.
enum CLILog {
    /// Receives every write. Replaced by `capture(_:)`; nil writes to the real streams.
    private static var sink: ((_ text: String, _ isError: Bool) -> Void)?

    /// The same sink, settable across an `await`: `capture(_:)` takes a synchronous
    /// body, which an async command cannot be. Tests only.
    static var sinkForTests: ((_ text: String, _ isError: Bool) -> Void)? {
        get { sink }
        set { sink = newValue }
    }

    /// Whether prose is dropped entirely, which `--json` switches on: the event stream
    /// carries everything as structured lines, so the sentences would only repeat it.
    static var proseSuppressed = false

    /// Writes `text` and a newline to standard output.
    static func line(_ text: String = "") { write(text + "\n") }

    /// Writes `text` to standard output unchanged. Silent under `--json`.
    static func write(_ text: String) {
        guard !proseSuppressed else { return }
        emit(text, isError: false)
    }

    /// Writes `text` and a newline to standard error. Silent under `--json`, where the
    /// failure travels as an `error` event instead.
    static func error(_ text: String) {
        guard !proseSuppressed else { return }
        emit(text + "\n", isError: true)
    }

    /// Writes a line of the machine-readable stream, which owns standard output whatever
    /// the prose is doing.
    static func data(_ text: String) { emit(text + "\n", isError: false) }

    /// Runs `body` with output collected instead of written.
    static func capture(_ body: () throws -> Void) rethrows -> (out: String, error: String) {
        var out = "", errors = ""
        let previous = sink
        sink = { text, isError in
            if isError { errors += text } else { out += text }
        }
        defer { sink = previous }
        try body()
        return (out, errors)
    }

    private static func emit(_ text: String, isError: Bool) {
        if let sink {
            sink(text, isError)
            return
        }
        let handle = isError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(text.utf8))
    }
}
