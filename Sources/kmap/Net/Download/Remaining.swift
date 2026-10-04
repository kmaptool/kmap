import Foundation

/// How much longer a transfer has to run, from what has actually arrived.
///
/// Bytes still to come divided by the rate since the transfer began. While bytes keep
/// arriving at a steady rate the answer counts down, which an average over finished parts
/// would not.
enum Remaining {
    /// Below this there is not enough of a sample to say anything: the connections are
    /// still opening and a rate taken here swings by orders of magnitude.
    static let settlesAfter: TimeInterval = 1

    /// Seconds still to come, or nil when it cannot honestly be said yet.
    ///
    /// - Parameters:
    ///   - received: bytes down the wire so far, including what is only part-way through.
    ///   - total: bytes expected in all. Stated by the server, or estimated.
    ///   - elapsed: how long this transfer has been running.
    ///   - alreadyOnDisk: bytes resumed rather than fetched. They count towards what is
    ///     left to do but not towards the rate, which a resume would otherwise overstate.
    static func seconds(
        received: Int64,
        total: Int64,
        elapsed: TimeInterval,
        alreadyOnDisk: Int64 = 0
    ) -> Double? {
        guard elapsed > settlesAfter else { return nil }
        let fetched = Double(received - alreadyOnDisk)
        guard fetched > 0 else { return nil }
        let rate = fetched / elapsed
        let left = Double(total - received)
        guard left > 0, rate > 0 else { return nil }
        let seconds = left / rate
        return seconds.isFinite ? seconds : nil
    }
}
