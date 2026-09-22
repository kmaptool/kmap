import Foundation

/// `kmap recover`: a third-party map read against OSM ground and written back out as a
/// style of kmap's own, their pictures on kmap's numbers. `--out` writes the style,
/// `--attach` puts it in the TYP library, `--sheet` writes the reassignment list.
extension CLI {
    static func recover(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract", "out", "sheet"])
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse(
                "usage: kmap recover <map.img> [--extract <file.pbf>]…"
                    + " [--out <style.typ.txt>] [--sheet <file>]"
            )
        }
        let extracts = flags.values("extract").map { Paths.expand($0) }
        let log = Log(showing: CLIOutput.showing)
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let report = try await StyleRecovery.run(
                img: Paths.expand(path),
                extracts: extracts,
                log: log,
                rulesDirectory: neutral
            )
            // Every stage appends and returns, so the log is printed after the run.
            for line in log.snapshot() { CLILog.line(line.text) }
            let ordered = report.outcomes.values.sorted {
                ($0.kind.rawValue, $0.type) < ($1.kind.rawValue, $1.type)
            }
            try printRecovery(report, ordered: ordered, sheet: flags.value("sheet"))
            reportRecoveryJSON(report, ordered: ordered, path: path, out: flags.value("out"))
            if let refusal = saveRecoveredStyle(
                report,
                mapPath: path,
                to: flags.value("out"),
                attach: flags.has("attach")
            ) {
                return refusal
            }
            if !report.style.isEmpty { printLeftovers(report) }
            return 0
        } catch StyleRecovery.Trouble.noExtracts(let frame) {
            return await suggestExtracts(for: frame, path: path)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
    }

    /// The pristine rule stage recovery reads and writes against.
    static func neutralRules(log: Log) async throws -> URL {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        return try await catalog.neutralRulesForRecovery(log: log, runner: ProcessRunner())
    }
}
