import Foundation

/// `kmap recover`: a third-party map read against OSM ground and written back out as a
/// style of kmap's own, their pictures on kmap's numbers. `--out` writes the style,
/// `--attach` puts it in the TYP library, `--sheet` writes the reassignment list.
extension CLI {
    static func recover(_ arguments: [String]) async -> Int32 {
        await interruptible { await recovering(arguments) }
    }

    private static func recovering(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract", "out", "sheet"])
        guard let path = flags.positionals.first, flags.positionals.count == 1 else {
            return CLIOutput.refuse(
                "usage: kmap recover <map.img> [--extract <file.pbf>]…"
                    + " [--out <style.typ.txt>] [--sheet <file>] [--attach]"
            )
        }
        // Refused before minutes of work: a typo or a value left off would be found only
        // when nothing was saved.
        let known: Set<String> = ["extract", "out", "sheet", "attach", "json", "verbose"]
        if let unknown = flags.names.subtracting(known).sorted().first {
            return CLIOutput.refuse("kmap recover does not know --\(unknown)")
        }
        if let bare = ["extract", "out", "sheet"].first(where: { flags.has($0) && flags.value($0) == nil }) {
            return CLIOutput.refuse("--\(bare) needs a value: --\(bare)=<path>")
        }
        for name in ["out", "sheet"] {
            guard let value = flags.value(name) else { continue }
            if FileTools.isDirectory(Paths.expand(value)) {
                return CLIOutput.refuse("--\(name): \(value) is a folder — name a file in it")
            }
            let folder = Paths.expand(value).deletingLastPathComponent()
            if !FileTools.isDirectory(folder) {
                return CLIOutput.refuse("--\(name): no folder \(Paths.display(folder)) to write into")
            }
        }
        let extracts = flags.values("extract").map { Paths.expand($0) }
        // Asked before the work, as the copy it may need is asked about; only once the map
        // and the extracts named are known to do.
        var attachTo: URL?
        if flags.has("attach") {
            do {
                try StyleRecovery.checkInputs(img: Paths.expand(path), extracts: extracts)
            } catch {
                return CLIOutput.failure("recover: \(CLIOutput.said(error))")
            }
            let entry = libraryEntry(forMap: path)
            guard let url = entry.url else { return entry.code }
            attachTo = url
        }
        let log = Log(showing: CLIOutput.showing)
        // Every stage appends and returns, so the log is printed after the run, and as
        // events under --json; on a failure too, whose warnings say why.
        var printer = LogPrinter()
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let report = try await StyleRecovery.run(
                img: Paths.expand(path),
                extracts: extracts,
                log: log,
                rulesDirectory: neutral
            )
            printer.drain(log)
            let ordered = report.outcomes.values.sorted {
                ($0.kind.rawValue, $0.type) < ($1.kind.rawValue, $1.type)
            }
            try printRecovery(report, ordered: ordered, sheet: nil)
            reportRecoveryJSON(report, ordered: ordered, path: path, out: flags.value("out"))
            if let refusal = saveRecoveredStyle(
                report,
                to: flags.value("out"),
                attach: attachTo
            ) {
                return refusal
            }
            // After the style is saved, so a sheet that will not write costs only itself.
            if let sheet = flags.value("sheet") {
                do {
                    try FileTools.write(report.sheet + "\n", to: Paths.expand(sheet))
                    CLILog.line("\nsheet -> \(sheet)")
                } catch {
                    return CLIOutput.failure("cannot write the sheet to \(sheet): \(ErrorWords.of(error))")
                }
            }
            if !report.style.isEmpty { printLeftovers(report) }
            return 0
        } catch StyleRecovery.Trouble.noExtracts(let frame) {
            printer.drain(log)
            return await suggestExtracts(for: frame, path: path)
        } catch let trouble as StyleRecovery.Trouble where extracts.isEmpty && trouble.isTooLittleGround {
            printer.drain(log)
            // The cached extracts it picked graze the map: the right one is to be downloaded.
            let frame = RegionSuggestion.drawnGround(of: Paths.expand(path)).frame
            return await suggestExtracts(for: frame, path: path, why: "\(trouble)")
        } catch  where Task.isCancelled {
            return CLIOutput.cancelled()
        } catch {
            printer.drain(log)
            return CLIOutput.failure("recover: \(CLIOutput.said(error))")
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
