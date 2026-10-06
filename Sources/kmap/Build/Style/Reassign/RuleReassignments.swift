import Foundation

/// Reassignments the user has made, kept where they can be read and edited by hand. Stored
/// in the same `@@ file` / `- old` / `+ new` form as the shipped substitutions and applied
/// by the same code, so a line that no longer matches the installed mkgmap is reported in
/// the build log rather than silently skipped.
enum RuleReassignments {
    static var file: URL { Paths.root.appendingPathComponent("reassignments.txt") }

    private static let header = """
        # Type reassignments you have made.
        #
        # A rule here moves one thing from the Garmin type code mkgmap's own style puts it
        # on to a different one. The format is kmap's usual exact-line substitution: '@@'
        # names the rule file, '-' is the line as mkgmap writes it, '+' is what it becomes.
        # A '-' line that no longer matches the installed mkgmap is reported in the build
        # log rather than silently skipped.
        #
        # Safe to edit by hand, and safe to delete: deleting a block simply puts that rule
        # back where mkgmap had it.

        """

    // MARK: Reading

    /// - Parameter file: passed only by tests, to point at a throwaway file.
    static func text(in file: URL = RuleReassignments.file) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// One recorded substitution. `SubstitutionSheet` is where the format lives.
    typealias Entry = SubstitutionSheet.Entry

    /// The substitutions, parsed back out, for listing and undoing.
    static func entries(in file: URL = RuleReassignments.file) -> [Entry] {
        SubstitutionSheet.parse(text(in: file))
    }

    static func isEmpty(in file: URL = RuleReassignments.file) -> Bool {
        entries(in: file).isEmpty
    }

    /// A short stamp of the current contents, for the materialized style's identity: without
    /// it, a build would reuse a style materialized before the reassignment was made.
    static func fingerprint(in file: URL = RuleReassignments.file) -> String {
        let list = entries(in: file)
        guard !list.isEmpty else { return "" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in list.map({ "\($0.file)\($0.old.joined())\($0.new.joined())" })
            .joined().utf8
        {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "+reassign-\(list.count)-" + String(hash & 0xFFFFFF, radix: 16)
    }

    // MARK: Writing

    enum StoreError: LocalizedError {
        case alreadyMoved(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyMoved(let line):
                return t("that rule has already been reassigned: %@", truncate(line, to: 60))
            case .failed(let why): return why
            }
        }
    }

    /// Records a reassignment, appending to whatever is already there.
    static func add(
        _ reassignment: RuleReassignment,
        to file: URL = RuleReassignments.file
    ) throws {
        // Two substitutions with the same `-` line would fight: the first applies and the
        // second then reports itself as missed.
        let old = reassignment.oldLines
        guard !entries(in: file).contains(where: { $0.old == old }) else {
            throw StoreError.alreadyMoved(old.first ?? "")
        }

        // A file that will not read as UTF-8 is still the user's: written over, every
        // entry in it would go.
        if FileTools.exists(file), (try? String(contentsOf: file, encoding: .utf8)) == nil {
            throw StoreError.failed(t("%@ is not UTF-8 text, so it is left as it is", Paths.display(file)))
        }
        var body = text(in: file)
        if body.isEmpty { body = header }
        // In the line ends the file already has, which a hand edit may have changed.
        let newline = newline(of: body)
        var block = ["", "@@ \(reassignment.file)"]
        // One marker per line, since a rule can span two of them and the applier joins the
        // replacement back together with newlines.
        block += old.map { "- " + $0 }
        block += reassignment.newLines.map { "+ " + $0 }
        body += block.dropFirst().reduce(block[0]) { $0 + newline + $1 } + newline
        try write(body, to: file)
    }

    /// Drops 1 substitution, putting that rule back where mkgmap had it. Only its own
    /// `@@`, `-` and `+` lines go: the file is the user's to annotate, and every comment
    /// stays where it was.
    static func remove(_ entry: Entry, from file: URL = RuleReassignments.file) throws {
        let all = entries(in: file)
        guard all.contains(entry) else { return }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }

        var lines = TextLines.keepingTrailingBlank(text)
        // Each entry's own lines, read as the sheet is read: a block can hold several.
        let runs = SubstitutionSheet.entryLines(lines)
        guard let at = SubstitutionSheet.parse(text).firstIndex(of: entry), at < runs.count else { return }
        var going = Set(runs[at].lines)
        // Its header too, where no other entry is left under it.
        if let header = runs[at].header,
            !runs.enumerated().contains(where: { $0.offset != at && $0.element.header == header })
        {
            going.insert(header)
        }
        for index in going.sorted(by: >) { lines.remove(at: index) }
        try write(lines.joined(separator: newline(of: text)), to: file)
    }

    /// The line end a text uses: Windows' where it has any, else the plain one.
    private static func newline(of text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    static func removeAll(at file: URL = RuleReassignments.file) throws {
        FileTools.removeIfPresent(file)
    }

    private static func write(_ body: String, to file: URL) throws {
        Paths.ensure(file.deletingLastPathComponent())
        do {
            try FileTools.write(body, to: file)
        } catch {
            throw StoreError.failed(error.localizedDescription)
        }
    }
}
