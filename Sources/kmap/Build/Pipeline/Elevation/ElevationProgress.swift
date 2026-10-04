import Foundation

/// The elevation download's progress line.
extension BuildPipeline {
    /// What the elevation download shows while it runs: tiles done, bytes, rate and time
    /// left. The total size is not known in advance, so the estimate rests on the weight
    /// of the tiles already finished.
    static func fetchLine(
        source: String = "Copernicus",
        done: Int,
        of total: Int,
        received: Int64,
        elapsed: TimeInterval,
        secondsLeft: Double?
    ) -> String {
        var text = "\(source) \(done)/\(total) · \(Fmt.bytes(received))"
        // No rate for the first second: the first tiles are still opening their
        // connections and the figure would swing wildly.
        guard elapsed > Remaining.settlesAfter, received > 0 else { return text }
        text += "  ·  \(Fmt.rate(Double(received) / elapsed))"
        guard let secondsLeft else { return text }
        return text + "  ·  \(Fmt.duration(secondsLeft)) left"
    }
}
