import Foundation

enum Fmt {
    /// Formats a byte count in decimal units: "1.4 GB", "812 MB", "43 kB", "7 B".
    static func bytes(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000: return "\(n) B"
        case ..<1_000_000: return String(format: "%.0f kB", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB", v / 1_000_000)
        default: return String(format: "%.2f GB", v / 1_000_000_000)
        }
    }

    /// Formats memory use as "12.4/64 GB". Both halves are in binary gigabytes and share
    /// one unit, which `Fmt.bytes` would not guarantee.
    static func memory(used: UInt64, total: UInt64) -> String {
        let gigabyte = 1_073_741_824.0
        let usedGB = Double(used) / gigabyte
        let totalGB = Double(total) / gigabyte
        return String(format: "%.1f/%.0f ", usedGB, totalGB) + t("GB")
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Formats a duration as "48s", "4m 12s" or "1h 03m"; "—" beyond 48 hours.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 60 * 60 * 48 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "  0%" }
        return String(format: "%3.0f%%", max(0, min(1, fraction)) * 100)
    }

    /// Formats degrees with a compass suffix.
    static func coord(_ value: Double, lat: Bool) -> String {
        let suffix = lat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        return String(format: "%.2f°%@", abs(value), suffix)
    }

    /// A formatter for a fixed pattern. The locale is pinned: a machine set to a
    /// non-Gregorian calendar — Thai, Japanese — writes another year into `yyyy`.
    private static func fixed(_ pattern: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = pattern
        df.timeZone = LocalTime.zone
        return df
    }

    /// The day alone, for something dated rather than timed.
    static func day(_ date: Date) -> String {
        fixed("yyyy-MM-dd").string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        fixed("yyyy-MM-dd HH:mm").string(from: date)
    }

    static func clock(_ date: Date = Date()) -> String {
        fixed("HH:mm:ss").string(from: date)
    }
}
