import Foundation

/// Reading OSM's `ele`: metres or feet, with the spellings people write.
extension BurnPeaks {
    static let metresPerFoot = 0.3048
    private static let feetSuffixes = ["feet", "ft", "'", "\u{2032}"]
    private static let metreSuffixes = ["metres", "meters", "m"]

    /// OSM `ele` as metres: `1527`, `1527.4`, `1527,4`, `1 527`, `1,527`, `1527 m`. Feet
    /// are converted where they are declared, `5000 ft`, `5000'`, `5000 feet`, and where
    /// nothing else fits: no summit stands 14,505 metres high, so that many is feet. Nil
    /// for anything else, or outside `range`. A wrong unit that fits is caught later, by
    /// the terrain: a height in feet read as metres is 3 times too high.
    static func metres(_ raw: String?) -> Double? {
        parse(raw, inFeet: false)
    }

    /// `ele:ft`, which some American summits carry instead of `ele`.
    static func metres(feet raw: String?) -> Double? {
        parse(raw, inFeet: true)
    }

    private static func parse(_ raw: String?, inFeet: Bool) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !text.isEmpty
        else { return nil }
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        text = text.replacingOccurrences(of: " ", with: "")
        var feet = inFeet
        if let suffix = feetSuffixes.first(where: { text.hasSuffix($0) }) {
            text = String(text.dropLast(suffix.count))
            feet = true
        } else if let suffix = metreSuffixes.first(where: { text.hasSuffix($0) }) {
            text = String(text.dropLast(suffix.count))
        }
        if text.contains(",") {
            // `1,527` and `1,527.4` group thousands; `1527,4` is a decimal comma.
            let grouped = text.contains(".") || groupsThousands(text)
            text = text.replacingOccurrences(of: ",", with: grouped ? "" : ".")
        }
        guard let value = Double(text) else { return nil }
        if !feet, value > range.upperBound, value * metresPerFoot <= range.upperBound {
            feet = true
        }
        let height = feet ? value * metresPerFoot : value
        return range.contains(height) ? height : nil
    }

    /// Whether every comma has exactly 3 digits after it, up to the next: `1,527`,
    /// `14,505`, but not `1527,4` or `1,5`.
    private static func groupsThousands(_ text: String) -> Bool {
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count > 1, let first = groups.first, (1...3).contains(first.count),
            first.allSatisfy(\.isNumber) || first.hasPrefix("-")
        else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }
}
