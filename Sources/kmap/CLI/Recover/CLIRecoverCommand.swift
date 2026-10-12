import Foundation

/// `kmap recover`: a third-party map read against OSM ground and written back out as a
/// style of kmap's own, their pictures on kmap's numbers. `--out` writes the style,
/// `--attach` puts it in the TYP library, `--sheet` writes the reassignment list.
/// Without `--extract` it reads the cached extracts, and downloads regions 1 at a time while
/// they hold too little of the map.
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
        if let refusal = refusal(of: flags) { return refusal }
        let named = flags.values("extract").map { Paths.expand($0) }
        // Asked before the work, as the copy it may need is asked about; only once the map
        // and the extracts named are known to do.
        var attachTo: URL?
        if flags.has("attach") {
            do {
                try StyleRecovery.checkInputs(img: Paths.expand(path), extracts: named)
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
        // Without --extract the cached extracts are read. Where they fall short, the region
        // the screen would offer is downloaded and the run goes again, as on the screen,
        // until the ground is enough or no region is left to download.
        while true {
            do {
                let neutral = try await neutralRules(log: log)
                defer { FileTools.removeIfPresent(neutral) }
                let report = try await StyleRecovery.run(
                    img: Paths.expand(path),
                    extracts: named,
                    log: log,
                    rulesDirectory: neutral
                )
                printer.drain(log)
                return try finish(report, flags: flags, path: path, attachTo: attachTo)
            } catch let trouble as StyleRecovery.Trouble
                where named.isEmpty && (trouble.isNoExtracts || trouble.isTooLittleGround)
            {
                printer.drain(log)
                do {
                    if try await downloadRegion(for: Paths.expand(path), log: log) { continue }
                    // Every region under the map is cached and tried: no download helps.
                    printer.drain(log)
                    return CLIOutput.failure(
                        "recover: the extracts kmap holds around this map do not cover what it draws"
                            + " (\(trouble)) - pass the extract of the region the map shows with --extract"
                    )
                } catch  where Task.isCancelled {
                    return CLIOutput.cancelled()
                } catch {
                    log.warn("the region could not be downloaded: \(CLIOutput.said(error))")
                    printer.drain(log)
                }
                let frame = RegionSuggestion.drawnGround(of: Paths.expand(path)).frame
                return await suggestExtracts(for: frame, path: path, why: trouble.isNoExtracts ? nil : "\(trouble)")
            } catch  where Task.isCancelled {
                return CLIOutput.cancelled()
            } catch {
                printer.drain(log)
                return CLIOutput.failure("recover: \(CLIOutput.said(error))")
            }
        }
    }

    /// What is wrong with the flags, said before minutes of work: a typo or a value left
    /// off would be found only when nothing was saved.
    private static func refusal(of flags: Flags) -> Int32? {
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
        return nil
    }

    /// The report printed and the style saved, then the sheet.
    private static func finish(
        _ report: StyleRecovery.Report,
        flags: Flags,
        path: String,
        attachTo: URL?
    ) throws -> Int32 {
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
    }

    /// The pristine rule stage recovery reads and writes against.
    static func neutralRules(log: Log) async throws -> URL {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        return try await catalog.neutralRulesForRecovery(log: log, runner: ProcessRunner())
    }
}
