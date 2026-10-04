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
            of: Self.bracket(fromCode),
            with: Self.bracket(toCode)
        )
        if !note.isEmpty { lines[index] += "  # kmap: \(note)" }
        return lines
    }

    /// The mark a reassigned rule carries in the file. Other passes read it to tell a
    /// number a person chose in the style editor from one kmap moved by itself.
    static let mark = "# kmap: was "

    /// `[0x2f06` - the opening of the type bracket, which is what identifies the code in
    /// the line. Matching the bare number would also hit a resolution or a coordinate.
    private static func bracket(_ code: Int) -> String { "[" + TypeMeaning.hex(code) }
}
