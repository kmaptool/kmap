import Foundation

/// Russian names for the hide catalogue, parsed from `Assets/hideable-ru.txt` and kept
/// beside the catalogue rather than in the string tables: the English names are generated
/// from mkgmap values, so keying by them would silently fall back on a rename. Keyed by
/// entry id instead; an entry with no Russian shows its English.
enum HideableNames {
    static func category(_ english: String) -> String {
        guard L10n.current == .ru else { return english }
        return tables.categories[english] ?? english
    }

    static func name(id: String, english: String) -> String {
        guard L10n.current == .ru else { return english }
        return tables.features[id] ?? english
    }

    /// The translated ids and headings, visible for the coverage tests.
    static var features: [String: String] { tables.features }
    static var categories: [String: String] { tables.categories }

    /// The asset, parsed once: `category|<english>|<russian>` for the section headings,
    /// `<feature-id>|<russian>` for the entries.
    private static let tables: (categories: [String: String], features: [String: String]) = {
        var categories: [String: String] = [:]
        var features: [String: String] = [:]
        for raw in StyleAssets.hideableRussianNames
            .split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "|", maxSplits: 2,
                                   omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0] == "category" {
                categories[parts[1]] = parts[2]
            } else if parts.count == 2 {
                features[parts[0]] = parts[1]
            }
        }
        return (categories, features)
    }()
}
