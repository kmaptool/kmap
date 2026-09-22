import Foundation

/// The hide catalogue rebuilt from the rules of a style materialized into a directory of
/// its own, read before the POI zoom shift and the label translation. Printed unless
/// `--out` names a file to write.
extension CLI {
    static func regenerateHideable(_ flags: Flags) async -> Int32 {
        let quiet = flags.has("quiet") || flags.value("out") == nil
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        if flags.value("points") == nil, toolchain.findMkgmap() == nil {
            return CLIOutput.refuse(
                t("mkgmap is needed to read the rules the catalogue is built from — run `kmap install mkgmap`")
            )
        }
        // A points file named outright needs no style materialized.
        if let given = flags.value("points") {
            do {
                let points = try String(contentsOfFile: given, encoding: .utf8)
                try reportCatalogue(HideableGenerator.catalogue(fromPoints: points), out: flags.value("out"))
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
            try await catalog.materializeRules(
                into: staging,
                descriptions: .off,
                cyrillicLabels: false,
                log: log,
                runner: ProcessRunner()
            )
            let points = try String(contentsOf: staging.appendingPathComponent("points"), encoding: .utf8)
            try reportCatalogue(HideableGenerator.catalogue(fromPoints: points), out: flags.value("out"))
            if !quiet {
                for line in log.snapshot().suffix(3) { CLILog.line("  \(line.text)") }
            }
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Writes the catalogue where it was asked for, and says the same in both shapes:
    /// the text itself for a person, its measurements for a program.
    private static func reportCatalogue(_ made: HideableGenerator.Result, out: String?) throws {
        if let out {
            try made.text.write(toFile: out, atomically: true, encoding: .utf8)
            CLILog.line(t("%@: %d hideable feature(s) across %d key(s)", out, made.features, made.keys))
        } else {
            CLILog.write(made.text)
        }
        // With no --out the text goes nowhere else, so the stream carries it whole.
        CLIOutput.result([
            "out": .of(out), "features": .int(made.features),
            "keys": .int(made.keys),
            "text": out == nil ? .string(made.text) : .null
        ])
    }
}
