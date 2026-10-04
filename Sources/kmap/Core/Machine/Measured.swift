import Foundation

/// Timing lines about kmap's own work, printed in a debug build or when `KMAP_TIMING`
/// is set, and suppressed otherwise.
enum Measured {
    /// Read once, since this is consulted from the paths it measures.
    private static let asked =
        ProcessInfo.processInfo.environment["KMAP_TIMING"] != nil

    static var reported: Bool {
        #if DEBUG
        return true
        #else
        return asked
        #endif
    }

    /// Returns a timing line for `what`, or nil when timing is off or the elapsed time
    /// is under `atLeast` seconds.
    static func line(_ what: String, since: Date, atLeast: Double = 0.2) -> String? {
        guard reported else { return nil }
        let seconds = Date().timeIntervalSince(since)
        guard seconds >= atLeast else { return nil }
        return String(
            format: "  %@ %.1f s, up to %@",
            what,
            seconds,
            Fmt.bytes(Machine.memoryInUse())
        )
    }
}
