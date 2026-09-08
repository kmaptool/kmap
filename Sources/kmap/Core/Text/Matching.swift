import Foundation

/// Regular-expression extraction from text.
///
/// Used on pages and banners not meant to be parsed, so an invalid pattern or a failed
/// match returns nothing rather than throwing; the caller reports the missing value.
extension String {
    /// Returns every non-overlapping whole match of `pattern`.
    func allMatches(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            Range(match.range, in: self).map { String(self[$0]) }
        }
    }

    /// Returns the first capture group of the first match of `pattern`, or nil.
    func firstCapture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[group])
    }
}
