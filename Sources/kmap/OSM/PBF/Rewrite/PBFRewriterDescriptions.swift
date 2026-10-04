import Foundation

/// Descriptions that only repeat the name beside them. mkgmap cannot compare two tags, so
/// they are dropped before the build. Only a repeat goes: a description that adds a word,
/// "Родник сух" beside "Родник", is kept.
extension PBFRewriter {
    /// In order of preference, so the choice does not depend on tag order in the file.
    private static let nameKeys = ["name", "name:ru"]
    private static let descriptionKeys = ["description", "description:ru", "description:en"]

    /// Drops any description that only repeats the name; returns how many were dropped.
    static func tidy(_ tags: inout [(String, String)]) -> Int {
        guard let name = Self.comparableName(tags) else { return 0 }
        let before = tags.count
        tags.removeAll { Self.saysNothingNew($0, $1, beside: name) }
        return before - tags.count
    }

    /// Whether `tidy` would drop anything, without building the tidied list.
    static func wouldTidy(_ tags: [(String, String)]) -> Bool {
        guard let name = Self.comparableName(tags) else { return false }
        return tags.contains { saysNothingNew($0.0, $0.1, beside: name) }
    }

    private static func comparableName(_ tags: [(String, String)]) -> String? {
        for key in nameKeys {
            guard let name = tags.first(where: { $0.0 == key })?.1 else { continue }
            let folded = fold(name)
            return folded.isEmpty ? nil : folded
        }
        return nil
    }

    /// Letters and digits only, lowercased: punctuation and spacing say nothing.
    private static func fold(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func saysNothingNew(_ key: String, _ value: String, beside name: String) -> Bool {
        guard descriptionKeys.contains(key) else { return false }
        let described = fold(value)
        return described.isEmpty || described == name
    }
}
