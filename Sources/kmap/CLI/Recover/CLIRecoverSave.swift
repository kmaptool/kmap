import Foundation

/// Where a recovered style lands: the file `--out` names, and the library entry this
/// map's TYP was imported as where `--attach` says so.
extension CLI {
    /// Saves what the recovery produced. Returns a failure code where something had
    /// nowhere to land, nil otherwise.
    static func saveRecoveredStyle(
        _ report: StyleRecovery.Report,
        to out: String?,
        attach typ: URL?
    ) -> Int32? {
        guard !report.style.isEmpty else {
            return out == nil && typ == nil
                ? nil
                : CLIOutput.failure("recover: nothing to save — no style was recovered")
        }
        if let out {
            let url = Paths.expand(out)
            do {
                try FileTools.write(TypSource.bytesOfWritten(report.style, codePage: report.codePage), to: url)
            } catch {
                return CLIOutput.failure("recover: \(CLIOutput.said(error))")
            }
            CLILog.line("style -> \(Paths.display(url))")
        }
        return typ.flatMap { updateLibraryStyle(report, at: $0) }
    }

    /// The library's editable copy of this map's TYP, found by fingerprint since a person
    /// may have renamed it. Where there is none, one is taken from the map, after the
    /// same copyright question `extract-typ` asks. Nil with the exit code where neither.
    static func libraryEntry(forMap path: String) -> (url: URL?, code: Int32) {
        let map = Paths.expand(path)
        if let name = TypLibrary.held().exact[TypLibrary.fingerprint(ofTypAt: map)],
            let typ = TypLibrary.contents().first(where: {
                // The source decompiled from it, beside its kept original: never the
                // binary, nor another file of that name.
                $0.deletingPathExtension().lastPathComponent == name && $0.pathExtension.lowercased() == "txt"
                    && TypLibrary.original(of: $0) != nil
            })
        {
            return (typ, 0)
        }
        guard !CLIOutput.isJSON else {
            return (
                nil,
                CLIOutput.refuse(
                    "--attach: this map's TYP is not in the library as an editable copy, and taking one"
                        + " asks a copyright confirmation, which --json cannot show — run it without --json"
                )
            )
        }
        guard confirmedCopyright(of: [path]) else {
            CLILog.line("nothing was imported")
            return (nil, CLIOutput.Exit.failed)
        }
        do {
            let taken = try TypLibrary.take(at: map)
            CLILog.line("\(taken.url.lastPathComponent) taken into the library")
            return (taken.url, 0)
        } catch {
            return (nil, CLIOutput.failure("--attach: \(CLIOutput.said(error))"))
        }
    }

    private static func updateLibraryStyle(_ report: StyleRecovery.Report, at typ: URL) -> Int32? {
        do {
            try TypLibrary.save(report.style, to: typ)
        } catch {
            return CLIOutput.failure("recover: \(CLIOutput.said(error))")
        }
        // The reassignment list went with the old file: no foreign numbers are left.
        if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
        // The id as the catalog numbers it, which `--style` matches.
        let library = TypLibrary.contents().compactMap(StyleCatalog.libraryStyle(at:)).sorted { $0.name < $1.name }
        let id =
            StyleCatalog.distinctIDs(library, owners: StyleIDOwners.load()).first {
                $0.typURL?.standardizedFileURL == typ.standardizedFileURL
            }?.id
            ?? "typ:" + FileTools.slugify(typ.deletingPathExtension().lastPathComponent)
        CLILog.line("\(typ.lastPathComponent) now draws this map's look — build with --style=\(id)")
        return nil
    }
}
