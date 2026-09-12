import Foundation

/// `kmap recover`: a third-party map read back into a style, then written to disk,
/// printed, or reported as JSON.
extension CLI {
    /// The pristine rule stage recovery reads and writes against.
    static func neutralRules(log: Log) async throws -> URL {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        return try await catalog.neutralRulesForRecovery(log: log,
                                                         runner: ProcessRunner())
    }

    /// `kmap recover <map.img> [--extract file.pbf]...` reads a third-party map and writes
    /// its look back out as a style of kmap's own: their pictures on kmap's numbers.
    static func recover(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract", "out", "sheet"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap recover <map.img> [--extract <file.pbf>]…"
                                     + " [--out <style.typ.txt>] [--sheet <file>]", code: 2)
        }
        let explicit = flags.values("extract").map { Paths.expand($0) }
        let log = Log(showing: CLIOutput.showing)
        // The log is drained after the run, since every stage appends and returns.
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let report = try await StyleRecovery.run(
                img: Paths.expand(path), extracts: explicit, log: log,
                rulesDirectory: neutral)
            for line in log.snapshot() { CLILog.line(line.text) }
            let ordered = report.outcomes.values.sorted {
                ($0.kind.rawValue, $0.type) < ($1.kind.rawValue, $1.type)
            }
            try printRecovery(report, ordered: ordered, sheet: flags.value("sheet"))
            reportRecoveryJSON(report, ordered: ordered, path: path,
                               out: flags.value("out"))
            if let refusal = writeRecoveredStyle(report, mapPath: path,
                                                 to: flags.value("out"),
                                                 adopt: flags.has("attach")) {
                return refusal
            }
            return 0
        } catch StyleRecovery.Trouble.noExtracts(let frame) {
            return await suggestExtracts(for: frame, path: path)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
    }

    /// Saves what the recovery produced - the style to `--out`, into the library where
    /// `--attach` says so - and names what had nowhere to land. Returns a failure code.
    private static func writeRecoveredStyle(_ report: StyleRecovery.Report,
                                            mapPath: String, to out: String?,
                                            adopt: Bool) -> Int32? {
        guard !report.style.isEmpty else {
            return out == nil && !adopt ? nil
                : CLIOutput.failure("recover: nothing to save — no style was recovered")
        }
        if let out {
            let url = Paths.expand(out)
            do {
                try report.style.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return CLIOutput.failure("recover: \(error)")
            }
            CLILog.line("style -> \(Paths.display(url))")
        }
        if adopt, let refusal = updateLibraryStyle(report, mapPath: mapPath) {
            return refusal
        }
        // One number of ours that several looks of theirs wanted: where a rule of
        // ours lumps together what their style tells apart.
        if !report.contested.isEmpty {
            CLILog.line("")
            CLILog.line("one number of ours, several looks of theirs (the winner first):")
            for port in report.contested {
                let kind = port.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                let rivals = port.rivals.map {
                    "\($0.meaning) <- 0x\(String($0.theirs, radix: 16)) (\($0.witnesses))"
                }.joined(separator: ", ")
                CLILog.line("  \(kind) 0x\(String(port.ours, radix: 16))"
                            + "  \(port.meaning) <- 0x\(String(port.theirs, radix: 16))"
                            + " (\(port.witnesses))  over  \(rivals)")
            }
        }
        // What their style draws and kmap has no number for: the list that says where
        // the rule base wants widening.
        guard !report.uncovered.isEmpty else { return nil }
        CLILog.line("")
        CLILog.line("their style draws these, and kmap's rules have no number for them:")
        for entry in report.uncovered.prefix(40) {
            let kind = entry.kind.rawValue.padding(toLength: 8, withPad: " ",
                                                   startingAt: 0)
            CLILog.line("  \(kind) 0x\(String(entry.theirs, radix: 16))"
                        + "  \(entry.meaning) — \(entry.witnesses) seen")
        }
        if report.uncovered.count > 40 {
            CLILog.line("  … and \(report.uncovered.count - 40) more")
        }
        return nil
    }

    /// The recovery on screen: the frame and one line per code. The reassignment list
    /// is written only where `--sheet` asks for it.
    private static func printRecovery(_ report: StyleRecovery.Report,
                                      ordered: [StyleRecovery.Outcome],
                                      sheet: String?) throws {
        CLILog.line("")
        CLILog.line("frame     \(report.frame.display)")
        CLILog.line("extracts  \(report.extracts.map(\.lastPathComponent).joined(separator: ", "))")
        CLILog.line("elements  \(report.elements)")
        CLILog.line("")
        for o in ordered {
            let code = String(format: "%@ 0x%05x", String(o.kind.rawValue), o.type)
            CLILog.line("\(code)  \(o.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + " witnesses=\(o.witnesses)/\(o.elements)"
                + (o.zooms.map { " " + $0 } ?? "")
                + (o.meaning.isEmpty ? "" : "  \(o.meaning)"))
        }
        if let sheet {
            try (report.sheet + "\n").write(to: Paths.expand(sheet),
                                             atomically: true, encoding: .utf8)
            CLILog.line("\nsheet -> \(sheet)")
        }
    }

    /// The same recovery in the structured shape.
    private static func reportRecoveryJSON(_ report: StyleRecovery.Report,
                                           ordered: [StyleRecovery.Outcome],
                                           path: String, out: String?) {
        CLIOutput.result([
            "map": .string(Paths.expand(path).path),
            "frame": ["minLat": .double(report.frame.minLat),
                      "minLon": .double(report.frame.minLon),
                      "maxLat": .double(report.frame.maxLat),
                      "maxLon": .double(report.frame.maxLon)],
            "extracts": .array(report.extracts.map { .string($0.path) }),
            "elements": .int(report.elements),
            "outcomes": .array(ordered.map { outcome in
                ["kind": .string(String(outcome.kind.rawValue)),
                 "type": .int(outcome.type),
                 "hex": .string(String(format: "0x%05x", outcome.type)),
                 "status": .string(outcome.status.rawValue),
                 "witnesses": .int(outcome.witnesses),
                 "elements": .int(outcome.elements),
                 "unmatched": .int(outcome.unmatched),
                 "ambiguous": .int(outcome.ambiguous),
                 "meaning": .string(outcome.meaning)]
            }),
            "sheet": .string(report.sheet),
            "contested": .array(report.contested.map { port in
                ["kind": .string(port.kind.rawValue), "ours": .int(port.ours),
                 "theirs": .int(port.theirs), "meaning": .string(port.meaning),
                 "witnesses": .int(port.witnesses),
                 "rivals": .array(port.rivals.map {
                     ["theirs": .int($0.theirs), "meaning": .string($0.meaning),
                      "witnesses": .int($0.witnesses)]
                 })]
            }),
            // The whole list, where the printed one stops at forty.
            "uncovered": .array(report.uncovered.map { entry in
                ["kind": .string(entry.kind.rawValue),
                 "theirs": .int(entry.theirs),
                 "hex": .string(String(format: "0x%05x", entry.theirs)),
                 "meaning": .string(entry.meaning),
                 "witnesses": .int(entry.witnesses)]
            }),
            "out": .of(out),
        ])
    }

    /// `--attach`: the library entry this map's TYP was imported as becomes the
    /// recovered style. Found by fingerprint, since a person may have renamed it.
    private static func updateLibraryStyle(_ report: StyleRecovery.Report,
                                           mapPath path: String) -> Int32? {
        let held = TypLibrary.held()
        guard let name = held.exact[TypLibrary.fingerprint(
            ofTypAt: Paths.expand(path))] else {
            return CLIOutput.failure("--attach: this map's TYP is not in the library"
                + " — import it first with: kmap extract-typ\n")
        }
        guard let typ = TypLibrary.contents().first(where: {
            $0.deletingPathExtension().lastPathComponent == name
        }) else {
            return CLIOutput.failure(
                "--attach: \(name) is listed but its file was not found")
        }
        do {
            try TypLibrary.save(report.style, to: typ)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
        // The reassignment list went with the old file: no foreign numbers are left.
        if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
        CLILog.line("\(typ.lastPathComponent) now draws this map's look"
                    + " — build with --style=typ:"
                    + typ.deletingPathExtension().lastPathComponent)
        return nil
    }

    /// What to do when no downloaded OSM data matches the map: name the candidate
    /// downloads rather than fetching them.
    private static func suggestExtracts(for frame: BBox, path: String) async -> Int32 {
        CLILog.error("recover: no downloaded OSM data matches \(frame.display)")
        let index = RegionIndex()
        guard (try? await index.load()) != nil else { return 1 }
        let wanted = RegionSuggestion.suggestedRegions(
            on: RegionSuggestion.drawnGround(of: Paths.expand(path)), index: index)
        guard !wanted.isEmpty else {
            return CLIOutput.failure("and no region kmap can download overlaps it either")
        }
        CLIOutput.result(["needsExtract": .bool(true),
                          "frame": ["minLat": .double(frame.minLat),
                                    "minLon": .double(frame.minLon),
                                    "maxLat": .double(frame.maxLat),
                                    "maxLon": .double(frame.maxLon)],
                          "suggested": .array(wanted.prefix(6).map { candidate in
                              ["region": .string(candidate.region.id),
                               "share": .double(candidate.share),
                               "drawnBytes": .double(candidate.drawn),
                               "inside": .double(candidate.inside)]
                          })])
        // One region inside the map suffices, so these are alternatives, not a set.
        CLILog.line("\nAny one of these regions is ground enough — download with:")
        for candidate in wanted.prefix(6) {
            CLILog.line(String(format: "  kmap build %@  (holds %.0f%% of the map's data,"
                         + " %.1f MB of it; %.0f%% of the region is under the map)",
                         candidate.region.id, candidate.share * 100,
                         candidate.drawn / 1_048_576, candidate.inside * 100))
        }
        CLILog.line("\nor pass an extract of your own with --extract=<file.osm.pbf>")
        return 1
    }
}
