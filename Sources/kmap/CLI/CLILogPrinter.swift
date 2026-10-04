import Foundation

/// Prints a run's log as it grows, in both shapes: the prose line with its mark, and the
/// event on the stream. A build and an install both follow a log this way.
extension CLI {
    struct LogPrinter {
        /// The number of the last event printed. Counted by number, not by place: the log
        /// keeps only its last 4000 events, and once it drops the oldest a place
        /// no longer names the same event.
        private var printedSeq = 0

        /// Prints what `log` has gained since the last call.
        mutating func drain(_ log: Log) {
            drain(log.snapshot())
        }

        /// The same, for a snapshot of the log taken by the caller. A mark goes above the
        /// first line written after its time. Lines numbered past `last` wait for the next
        /// call.
        mutating func drain(_ lines: [LogEvent], marks: [(at: Date, mark: Item)] = [], through last: Int = .max) {
            let fresh = lines.filter { $0.seq > printedSeq && $0.seq <= last }
            for item in Self.interleaved(fresh, marks: marks) {
                switch item {
                case .heading(let text):
                    CLILog.line(text)
                case .stage(let stage, let status, let detail):
                    CLIOutput.stage(stage.rawValue, status.rawValue, title: stage.title, detail: detail)
                case .line(let line):
                    CLILog.line(Self.prefix(line) + line.text)
                    CLIOutput.log(line)
                }
            }
            printedSeq = fresh.reduce(printedSeq) { max($0, $1.seq) }
        }

        enum Item {
            case heading(String)
            /// A stage's new status, for the stream.
            case stage(BuildPipeline.StageID, BuildPipeline.StageStatus, detail: String)
            case line(LogEvent)
        }

        /// The lines in their order, each mark above the first line as late as itself, and
        /// marks of the same time in the order given; a mark later than every line comes
        /// last.
        static func interleaved(_ lines: [LogEvent], marks: [(at: Date, mark: Item)]) -> [Item] {
            var waiting = marks.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
                .map(\.element)[...]
            var out: [Item] = []
            for line in lines {
                while let next = waiting.first, next.at <= line.at {
                    out.append(next.mark)
                    waiting = waiting.dropFirst()
                }
                out.append(.line(line))
            }
            return out + waiting.map(\.mark)
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
