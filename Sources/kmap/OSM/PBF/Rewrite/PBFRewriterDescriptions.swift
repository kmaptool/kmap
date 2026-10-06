import Foundation

/// Descriptions that only repeat the name beside them. mkgmap cannot compare two tags, so
/// they are dropped before the build. Only a repeat goes: a description that adds a word,
/// "Родник сух" beside "Родник", is kept.
extension PBFRewriter {
    /// Every name a label may be made of, in whichever language the map is labelled.
    private static let nameKeys = ["name", "name:ru"]
    private static let descriptionKeys = ["description", "description:ru", "description:en"]
    /// What stands in a label instead of the Russian word for the kind of thing.
    private static let labelTakers = ["brand", "operator"]

    /// Drops any description that only repeats the name; returns how many were dropped.
    /// `wordStays` where the style writes the word beside a brand or an operator too.
    static func tidy(_ tags: inout [(String, String)], wordStays: Bool = false) -> Int {
        let names = Self.comparableNames(tags, wordStays: wordStays)
        guard !names.isEmpty else { return 0 }
        let before = tags.count
        tags.removeAll { Self.saysNothingNew($0, $1, beside: names) }
        return before - tags.count
    }

    /// Whether `tidy` would drop anything, without building the tidied list.
    static func wouldTidy(_ tags: [(String, String)], wordStays: Bool = false) -> Bool {
        let names = Self.comparableNames(tags, wordStays: wordStays)
        guard !names.isEmpty else { return false }
        return tags.contains { saysNothingNew($0.0, $0.1, beside: names) }
    }

    /// The label's names as words: the object's own, or for an unnamed one the Russian word
    /// for its kind that the map writes instead, then its ref.
    private static func comparableNames(_ tags: [(String, String)], wordStays: Bool) -> [[String]] {
        // Most objects carry no description, and nothing more is asked of them.
        guard tags.contains(where: { descriptionKeys.contains($0.0) }) else { return [] }
        var out: [[String]] = []
        for key in nameKeys {
            guard let name = tags.first(where: { $0.0 == key })?.1 else { continue }
            let words = Self.words(name)
            if !words.isEmpty { out.append(words) }
        }
        guard out.isEmpty, wordStays || !tags.contains(where: { labelTakers.contains($0.0) }) else { return out }
        let ref = tags.first { $0.0 == "ref" }.map { Self.words($0.1) } ?? []
        for (key, value) in tags {
            guard let label = MakeGPI.russianLabels["\(key)=\(value)"] else { continue }
            let words = Self.words(label) + ref
            if !words.isEmpty { out.append(words) }
        }
        return out
    }

    /// Whether a way keeps the word beside a brand or an operator: the lines rules name an
    /// open way and any barrier whatever else it carries.
    static func wordStays(refs: [Int64], tags: [(String, String)]) -> Bool {
        refs.first != refs.last || refs.count < 2 || tags.contains { $0.0 == "barrier" }
    }

    /// The words of a text, lowercased: punctuation and spacing say nothing.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// A description that is a name, or whole words of one in order, adds nothing to the
    /// label: "Spring" beside "Holy Spring" goes, "closed" beside "Closedown Beach" stays.
    private static func saysNothingNew(_ key: String, _ value: String, beside names: [[String]]) -> Bool {
        guard descriptionKeys.contains(key) else { return false }
        let described = words(value)
        guard !described.isEmpty else { return true }
        return names.contains { name in
            name.count >= described.count
                && (0...(name.count - described.count)).contains {
                    Array(name[$0..<($0 + described.count)]) == described
                }
        }
    }
}
