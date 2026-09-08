import Foundation

/// `kmap hideable`: one word for two operations. Bare, it lists what can be left off the
/// map; with `--regenerate`, `--out` or `--points` it rebuilds the catalogue from the
/// rules of a freshly materialized style.
extension CLI {

    /// Lists the hideable features, grouped by category, filtered by `matching` when the
    /// user typed anything after the command.
    static func listHideable(matching filter: String) -> Int32 {
        let wanted = filter.lowercased()
        var category = ""
        var listed: [JSONValue] = []
        // From the content: these ids come out of a style and are not a fixed set.
        let idColumn = HideableFeature.all.map(\.id.count).max() ?? 0
        for feature in HideableFeature.all {
            guard wanted.isEmpty
                || feature.name.lowercased().contains(wanted)
                || feature.localizedName.lowercased().contains(wanted)
                || feature.id.lowercased().contains(wanted)
                || feature.category.lowercased().contains(wanted)
                || feature.localizedCategory.lowercased().contains(wanted) else { continue }
            if feature.category != category {
                category = feature.category
                CLILog.line("\n\(feature.localizedCategory)")
            }
            let id = feature.id
                + String(repeating: " ", count: max(0, idColumn - feature.id.count))
            CLILog.line("  \(id)  \(feature.localizedName)")
            listed.append(["id": .string(feature.id), "name": .string(feature.name),
                           "category": .string(feature.category),
                           "note": .string(feature.note)])
        }
        CLILog.line("\n\(HideableFeature.all.count) hideable feature(s). Use with: kmap build … --hide=a,b")
        CLIOutput.result(["features": .array(listed),
                          "total": .int(HideableFeature.all.count)])
        return 0
    }

    /// Regenerates the catalogue of features that can be left off the map, from the rules
    /// of a style materialized into a directory of its own, read before the POI zoom shift
    /// and the label translation. Prints the catalogue unless `--out` names a file to write.
    static func hideable(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["out", "points"])
        let quiet = flags.has("quiet") || flags.value("out") == nil
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        if flags.value("points") == nil, toolchain.findMkgmap() == nil {
            return CLIOutput.failure(t("mkgmap is needed to read the rules the catalogue is"
                 + " built from — run `kmap install mkgmap`"), code: 2)
        }
        // A points file named outright. Without it the rules come from a style materialized
        // here.
        if let given = flags.value("points") {
            do {
                let made = HideableGenerator.catalogue(
                    fromPoints: try String(contentsOfFile: given, encoding: .utf8))
                try reportCatalogue(made, out: flags.value("out"))
                return 0
            } catch {
                return CLIOutput.failure("\(error)")
            }
        }
        let log = Log(showing: CLIOutput.showing)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let staging = Paths.styles.appendingPathComponent("hideable-\(UUID().uuidString.prefix(8))")
        defer { FileTools.removeIfPresent(staging) }
        do {
            try await catalog.materializeRules(into: staging, descriptions: .off,
                                               cyrillicLabels: false, log: log,
                                               runner: ProcessRunner())
            let points = try String(contentsOf: staging.appendingPathComponent("points"),
                                    encoding: .utf8)
            let made = HideableGenerator.catalogue(fromPoints: points)
            try reportCatalogue(made, out: flags.value("out"))
            if !quiet {
                for line in log.snapshot().suffix(3) { CLILog.line("  \(line.text)") }
            }
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Writes the regenerated catalogue where it was asked for, and says the same in both
    /// shapes: the text itself for a person, its measurements for a program.
    private static func reportCatalogue(_ made: HideableGenerator.Result, out: String?) throws {
        if let out {
            try made.text.write(toFile: out, atomically: true, encoding: .utf8)
            CLILog.line(t("%@: %d hideable feature(s) across %d key(s)", out,
                          made.features, made.keys))
        } else {
            CLILog.write(made.text)
        }
        // With no --out the text goes nowhere else, so the stream carries it whole.
        CLIOutput.result(["out": .of(out), "features": .int(made.features),
                          "keys": .int(made.keys),
                          "text": out == nil ? .string(made.text) : .null])
    }
}
