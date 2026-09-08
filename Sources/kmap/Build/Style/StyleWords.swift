import Foundation

/// The words kmap itself writes onto the map — labels for objects OSM leaves unnamed,
/// and the notes appended to named ones — in the two languages a build can be labelled
/// in. Parsed from `Assets/style-words.txt`; the rules quote entries by key.
struct StyleWords {
    /// Whether this build labels in Russian; see `StyleChoices.cyrillic`.
    let cyrillic: Bool

    /// The word under `key`, in the build's language. A key the asset does not carry is
    /// a programming error — the tests run every builder in both languages — and comes
    /// back as the key itself so a release build still labels something.
    func callAsFunction(_ key: String) -> String {
        guard let pair = StyleWords.table[key] else {
            assertionFailure("style-words.txt has no entry for \(key)")
            return key
        }
        return cyrillic ? pair.ru : pair.en
    }

    /// Whether the asset knows `key` — for the repair labels, whose keys come from OSM
    /// values rather than from code.
    static func knows(_ key: String) -> Bool { table[key] != nil }

    /// The asset, parsed once: `<key>|<english>|<russian>`.
    static let table: [String: (en: String, ru: String)] = {
        var out: [String: (en: String, ru: String)] = [:]
        for raw in StyleAssets.styleWords.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "|", maxSplits: 2,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            out[parts[0]] = (en: parts[1], ru: parts[2])
        }
        return out
    }()
}
