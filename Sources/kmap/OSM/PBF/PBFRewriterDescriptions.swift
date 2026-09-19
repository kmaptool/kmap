import Foundation

/// Descriptions that only repeat the name beside them. mkgmap cannot compare two tags, so
/// they are dropped before the build.
extension PBFRewriter {
    private static let nameKeys = ["name", "name:ru"]
    private static let descriptionKeys = ["description", "description:ru", "description:en"]
    /// A description this close in length to the name, one containing the other, adds
    /// nothing to it.
    private static let nearlyTheName = 6

    /// Drops any description that only repeats the name, and returns how many were
    /// dropped. mkgmap cannot compare two tags, so this happens before the build.
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

    /// The name a description is measured against, folded for comparison.
    private static func comparableName(_ tags: [(String, String)]) -> String? {
        guard let name = tags.first(where: { nameKeys.contains($0.0) })?.1,
            !name.isEmpty
        else { return nil }
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.isEmpty ? nil : folded
    }

    private static func saysNothingNew(
        _ key: String,
        _ value: String,
        beside name: String
    ) -> Bool {
        guard descriptionKeys.contains(key) else { return false }
        let described = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if described.isEmpty || described == name { return true }
        return (described.contains(name) || name.contains(described))
            && abs(described.count - name.count) < nearlyTheName
    }
}
