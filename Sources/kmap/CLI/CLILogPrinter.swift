import Foundation

/// Prints a run's log as it grows, in both shapes: the prose line with its mark, and the
/// event on the stream. A build and an install both follow a log this way.
extension CLI {
    struct LogPrinter {
        /// The number of the last event printed. Counted by number, not by place: the log
        /// keeps only its last 4000 events, and once it drops the oldest a place
        /// no longer names the same event.
        private var printedSeq = 0

        /// Prints what `log` has gained since the last call. A heading, given with the
        /// time its stage set to work, goes above the first line written after that.
        mutating func drain(_ log: Log, headings: [(at: Date, text: String)] = []) {
            drain(log.snapshot(), headings: headings)
        }

        /// The same, for a snapshot of the log taken by the caller.
        mutating func drain(_ lines: [LogEvent], headings: [(at: Date, text: String)] = []) {
            let fresh = lines.filter { $0.seq > printedSeq }
            for item in Self.interleaved(fresh, headings: headings) {
                switch item {
                case .heading(let text):
                    CLILog.line(text)
                case .line(let line):
                    CLILog.line(Self.prefix(line) + line.text)
                    CLIOutput.log(line)
                }
            }
            if let last = lines.last { printedSeq = max(printedSeq, last.seq) }
        }

        enum Item {
            case heading(String)
            case line(LogEvent)
        }

        /// The lines in their order, each heading above the first line as late as itself;
        /// a heading later than every line comes last.
        static func interleaved(_ lines: [LogEvent], headings: [(at: Date, text: String)]) -> [Item] {
            var waiting = headings.sorted { $0.at < $1.at }[...]
            var out: [Item] = []
            for line in lines {
                while let next = waiting.first, next.at <= line.at {
                    out.append(.heading(next.text))
                    waiting = waiting.dropFirst()
                }
                out.append(.line(line))
            }
            return out + waiting.map { .heading($0.text) }
        }

        /// The mark in front of a line: what kind of thing it is first, how much it
        /// matters where the kind says nothing. Printed straight out rather than drawn on
        /// a `Surface`, so the substitution a Windows console needs is made here.
        static func prefix(_ event: LogEvent) -> String {
            switch event.kind {
            case .step: return "> "
            case .ok: return "\(Glyph.drawable("✓")) "
            case .plain, .output:
                switch event.severity {
                case .warn: return "! "
                case .error: return "\(Glyph.drawable("✕")) "
                case .debug, .info: return "  "
                }
            }
        }
    }
}
