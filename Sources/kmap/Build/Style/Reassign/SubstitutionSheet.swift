import Foundation

/// The `@@ file` / `- old` / `+ new` sheet, read in one place for everyone who needs it.
///
/// Three things are written in this form — kmap's shipped substitution lists, the
/// reassignments a person makes by hand, and the sheet `kmap recover` derives from a
/// foreign map — and two things read it: the build, which applies it, and the
/// reassignment screen, which lists and undoes it. Two readers with a parser each drifted
/// on the one corner they were both sure of, and a deletion followed by prose became two
/// entries for one of them and one entry for the other. One parser, and the listing is
/// the application.
enum SubstitutionSheet {

    /// One substitution: a run of lines as the rule file has them, and what they become.
    struct Entry: Equatable {
        /// Which rule file the lines live in: `points`, `lines` or `polygons`.
        let file: String
        /// The rule as the file writes it, one element per line — two where a condition
        /// and its type are written apart. Replaced whole.
        let old: [String]
        /// What it becomes. Empty means the rule is deleted.
        let new: [String]

        /// The first line, which is what a block is identified by.
        var key: String { old.first ?? "" }
    }

    /// Reads the sheet. Adjacent `-` lines are ONE entry over that many lines: a rule
    /// mkgmap writes across two lines has to be replaced across both, or the old type
    /// line stays behind as half a rule, and mkgmap says "Stack size is 0" about the
    /// style rather than the sheet. Adjacent means touching — a comment, a blank line or
    /// a `+` ends the run, so a `-` with no `+` is that one rule deleted and never
    /// swallows the next entry through the prose between them.
    static func parse(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var file = ""
        var old: [String] = []
        var new: [String] = []
        var previousWasMinus = false

        func flush() {
            if !old.isEmpty { out.append(Entry(file: file, old: old, new: new)) }
            old = []
            new = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@ ") {
                flush()
                file = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                if !previousWasMinus { flush() }
                old.append(String(line.dropFirst(2)))
                previousWasMinus = true
                continue
            } else if line.hasPrefix("+ ") {
                new.append(String(line.dropFirst(2)))
            }
            previousWasMinus = false
        }
        flush()
        return out
    }
}
