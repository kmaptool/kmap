import Foundation

/// The log of imports: which source each TYP in the library was taken from.
extension TypLibrary {
    /// The log of what was taken in, from where, and when. A `.log` beside the styles
    /// rather than inside them: `contents` lists only `.typ` and `.txt`, so it is not
    /// itself a style.
    static func importLog(in directory: URL = TypLibrary.directory) -> URL {
        directory.appendingPathComponent("imported.log")
    }

    /// Appends one line to that log. Failure is ignored: a note about an import is not
    /// worth failing the import over.
    static func recordImport(
        from source: URL,
        to destination: URL,
        at when: Date = Date(),
        fingerprint mark: UInt64 = 0,
        note: String,
        in directory: URL = TypLibrary.directory
    ) {
        let stamp = ISO8601DateFormatter().string(from: when)
        // The fingerprint answers what the path cannot once the drive it names is gone:
        // whether the file kept in originals/ is still the one taken that day.
        let identity = mark == 0 ? "-" : String(format: "%016llx", mark)
        let line =
            "\(stamp)\t\(destination.lastPathComponent)\t\(identity)"
            + "\t\(source.path)\t\(note)\n"
        let url = importLog(in: directory)
        Paths.ensure(directory)
        // Read, appended and rewritten whole: the log is small, and only FileTools
        // writes files, so Windows gets its retries.
        let sofar = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileTools.write(sofar + line, to: url)
    }

    /// The map a library entry was taken out of, from the latest import-log line naming
    /// it, and only while that path is still a Garmin container.
    ///
    /// The log has 2 shapes, with and without the fingerprint column, so the path is found by
    /// ruling the fingerprint out, not by counting columns or by a leading slash, which a
    /// Windows path (`C:\`) lacks.
    static func importedSource(
        of entry: URL,
        library: URL = TypLibrary.directory
    ) -> URL? {
        guard let text = try? String(contentsOf: importLog(in: library), encoding: .utf8)
        else { return nil }
        let name = entry.lastPathComponent
        for line in TextLines.of(text).reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 3, fields[1] == name else { continue }
            let path = isFingerprint(fields[2]) ? fields.dropFirst(3).first : fields[2]
            // An empty path: the entry was deleted or renamed away since.
            guard let path, !path.isEmpty else { return nil }
            let source = URL(fileURLWithPath: path)
            return FileTools.exists(source) && ImgContainer.isImg(source) ? source : nil
        }
        return nil
    }

    /// Moves an entry's latest log line to its new name, or with `to` nil forgets it: a
    /// style later taking the name must not inherit another's map.
    static func carryImport(of entry: URL, to moved: URL?, library: URL = TypLibrary.directory) {
        let url = importLog(in: library)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let name = entry.lastPathComponent
        var added = ""
        if let moved,
            let line = TextLines.of(text).last(where: {
                $0.split(separator: "\t").dropFirst().first.map(String.init) == name
            })
        {
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            fields[1] = moved.lastPathComponent
            added += fields.joined(separator: "\t") + "\n"
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        added += "\(stamp)\t\(name)\t-\t\t\(moved == nil ? "deleted" : "renamed")\n"
        let sofar = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        try? FileTools.write(sofar + added, to: url)
    }

    /// Whether a field is the fingerprint column: sixteen hex digits, or the dash written
    /// where there was nothing to fingerprint. Nothing else is that shape, and a path
    /// never is - it has a separator in it.
    private static func isFingerprint(_ field: String) -> Bool {
        if field == "-" { return true }
        return field.count == 16 && field.allSatisfy(\.isHexDigit)
    }
}
