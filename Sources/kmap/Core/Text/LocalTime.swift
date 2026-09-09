import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif

/// The zone displayed times are shown in.
///
/// `TimeZone.current` is UTC on Windows, where Foundation has no zone database; the C
/// runtime's offset is used there instead, as a fixed-offset zone. Displayed times need
/// no historical rules, so no named zone is required.
extension TimeInterval {
    /// A day in seconds, for the intervals kmap counts in days.
    static let day: TimeInterval = 24 * 3600
}

enum LocalTime {

    /// The zone to show times in: `TimeZone.current` everywhere but Windows.
    static let zone: TimeZone = resolve()

    private static func resolve() -> TimeZone {
        #if os(Windows)
        // One instant read as UTC then re-read as local; the difference is the offset.
        // `tm_isdst = -1` lets the runtime decide whether summer time applies.
        var now = time_t()
        time(&now)
        var utc = tm()
        guard gmtime_s(&utc, &now) == 0 else { return TimeZone.current }
        utc.tm_isdst = -1
        let asLocal = mktime(&utc)
        guard asLocal != -1 else { return TimeZone.current }
        let offset = Int(now - asLocal)
        // No real zone is more than fourteen hours from UTC.
        guard abs(offset) <= 14 * 3600, let zone = TimeZone(secondsFromGMT: offset) else {
            return TimeZone.current
        }
        return zone
        #else
        return TimeZone.current
        #endif
    }
}
