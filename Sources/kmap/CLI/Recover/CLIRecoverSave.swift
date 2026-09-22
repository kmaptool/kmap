import Foundation

/// Where a recovered style lands: the file `--out` names, and the library entry this
/// map's TYP was imported as where `--attach` says so.
extension CLI {
    /// Saves what the recovery produced. Returns a failure code where something had
    /// nowhere to land, nil otherwise.
    static func saveRecoveredStyle(
        _ report: StyleRecovery.Report,
        mapPath: String,
        to out: String?,
        attach: Bool
    ) -> Int32? {
        guard !report.style.isEmpty else {
            return out == nil && !attach
                ? nil
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
        return attach ? updateLibraryStyle(report, mapPath: mapPath) : nil
    }

    /// The library entry becomes the recovered style. Found by fingerprint, since a
    /// person may have renamed it.
    private static func updateLibraryStyle(_ report: StyleRecovery.Report, mapPath path: String) -> Int32? {
        let held = TypLibrary.held()
        guard let name = held.exact[TypLibrary.fingerprint(ofTypAt: Paths.expand(path))] else {
            return CLIOutput.failure(
                "--attach: this map's TYP is not in the library — import it first with: kmap extract-typ\n"
            )
        }
        guard
            let typ = TypLibrary.contents().first(where: {
                $0.deletingPathExtension().lastPathComponent == name
            })
        else {
            return CLIOutput.failure("--attach: \(name) is listed but its file was not found")
        }
        do {
            try TypLibrary.save(report.style, to: typ)
        } catch {
            return CLIOutput.failure("recover: \(error)")
        }
        // The reassignment list went with the old file: no foreign numbers are left.
        if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
        CLILog.line(
            "\(typ.lastPathComponent) now draws this map's look"
                + " — build with --style=typ:" + typ.deletingPathExtension().lastPathComponent
        )
        return nil
    }
}
