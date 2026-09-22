import Foundation

/// Prints a run's log as it grows, in both shapes: the prose line with its mark, and the
/// event on the stream. A build and an install both follow a log this way.
extension CLI {
    struct LogPrinter {
        private var printed = 0

        /// Prints what `log` has gained since the last call.
        mutating func drain(_ log: Log) {
            let lines = log.snapshot()
            guard lines.count > printed else { return }
            for line in lines[printed...] {
                CLILog.line(Self.prefix(line) + line.text)
                CLIOutput.log(line)
            }
            printed = lines.count
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
