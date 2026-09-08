import Foundation

/// One rule moved from the Garmin type it was emitting to a different one.
struct RuleReassignment: Equatable {
    /// Which rule file the line lives in: `points`, `lines` or `polygons`.
    let file: String

    /// The rule exactly as the file has it, spanning both lines where the condition and its
    /// type are written apart. Not rebuilt from its parts: an exact-line substitution that
    /// differs in spacing, line breaks or action blocks matches nothing.
    let raw: String

    let fromCode: Int
    let toCode: Int
    /// Why, recorded beside the change as the shipped substitution lists do.
    let note: String

    var oldLines: [String] { raw.components(separatedBy: "\n") }

    /// The same text with the type swapped, and the reason appended to its last line.
    var newLines: [String] {
        var lines = oldLines
        guard let index = lines.lastIndex(where: { $0.contains(Self.bracket(fromCode)) })
        else { return lines }
        lines[index] = lines[index].replacingOccurrences(
            of: Self.bracket(fromCode), with: Self.bracket(toCode))
        if !note.isEmpty { lines[index] += "  # kmap: \(note)" }
        return lines
    }

    /// The mark a reassigned rule carries in the file. Other passes read it to tell a
    /// number a person chose in the style editor from one kmap moved by itself.
    static let mark = "# kmap: was "

    /// `[0x2f06` — the opening of the type bracket, which is what identifies the code in
    /// the line. Matching the bare number would also hit a resolution or a coordinate.
    private static func bracket(_ code: Int) -> String { "[" + TypeMeaning.hex(code) }
}

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
            .joined().utf8 {
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
    static func add(_ reassignment: RuleReassignment,
                    to file: URL = RuleReassignments.file) throws {
        // Two substitutions with the same `-` line would fight: the first applies and the
        // second then reports itself as missed.
        let old = reassignment.oldLines
        guard !entries(in: file).contains(where: { $0.old == old }) else {
            throw StoreError.alreadyMoved(old.first ?? "")
        }

        var body = text(in: file)
        if body.isEmpty { body = header }
        body += "\n@@ \(reassignment.file)\n"
        // One marker per line, since a rule can span two of them and the applier joins the
        // replacement back together with newlines.
        body += old.map { "- " + $0 }.joined(separator: "\n") + "\n"
        body += reassignment.newLines.map { "+ " + $0 }.joined(separator: "\n") + "\n"
        try write(body, to: file)
    }

    /// Drops one substitution, putting that rule back where mkgmap had it. The file is
    /// rewritten from what is left, so a block spanning several lines goes whole.
    static func remove(_ entry: Entry, from file: URL = RuleReassignments.file) throws {
        let keep = entries(in: file).filter { $0 != entry }
        guard keep.count != entries(in: file).count else { return }
        guard !keep.isEmpty else { return try removeAll(at: file) }

        var body = header
        for item in keep {
            body += "\n@@ \(item.file)\n"
            body += item.old.map { "- " + $0 }.joined(separator: "\n") + "\n"
            body += item.new.map { "+ " + $0 }.joined(separator: "\n") + "\n"
        }
        try write(body, to: file)
    }

    static func removeAll(at file: URL = RuleReassignments.file) throws {
        FileTools.removeIfPresent(file)
    }

    private static func write(_ body: String, to file: URL) throws {
        Paths.ensure(file.deletingLastPathComponent())
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.failed(error.localizedDescription)
        }
    }
}
