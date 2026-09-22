import Foundation

/// `kmap hideable`: one word for two operations. Bare, it lists what `--hide` can leave
/// off the map, filtered by whatever was typed after it; with `--regenerate`, `--out` or
/// `--points` it rebuilds the catalogue from the style's own rules.
extension CLI {
    static func hideable(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["out", "points"])
        if flags.has("regenerate") || flags.has("out") || flags.has("points") {
            return await regenerateHideable(flags)
        }
        return listHideable(matching: arguments.joined(separator: " "))
    }

    /// The hideable features, grouped by category.
    static func listHideable(matching filter: String) -> Int32 {
        let wanted = filter.lowercased()
        var category = ""
        var listed: [JSONValue] = []
        // From the content: these ids come out of a style and are not a fixed set.
        let idColumn = HideableFeature.all.map(\.id.count).max() ?? 0
        for feature in HideableFeature.all where matches(feature, wanted) {
            if feature.category != category {
                category = feature.category
                CLILog.line("\n\(feature.localizedCategory)")
            }
            let id = feature.id + String(repeating: " ", count: max(0, idColumn - feature.id.count))
            CLILog.line("  \(id)  \(feature.localizedName)")
            listed.append([
                "id": .string(feature.id), "name": .string(feature.name),
                "category": .string(feature.category),
                "note": .string(feature.note)
            ])
        }
        CLILog.line("\n\(HideableFeature.all.count) hideable feature(s). Use with: kmap build … --hide=a,b")
        CLIOutput.result([
            "features": .array(listed),
            "total": .int(HideableFeature.all.count)
        ])
        return 0
    }

    /// Whether the filter, already lowercased, finds the feature by any of its names.
    private static func matches(_ feature: HideableFeature, _ wanted: String) -> Bool {
        wanted.isEmpty
            || feature.name.lowercased().contains(wanted)
            || feature.localizedName.lowercased().contains(wanted)
            || feature.id.lowercased().contains(wanted)
            || feature.category.lowercased().contains(wanted)
            || feature.localizedCategory.lowercased().contains(wanted)
    }
}
