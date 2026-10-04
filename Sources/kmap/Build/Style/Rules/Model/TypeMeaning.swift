import Foundation

/// What one Garmin type code means, in OSM terms. A TYP styles codes and records nothing
/// about what they stand for; a code means whatever the rule set emitting it puts there.
struct TypeMeaning: Equatable {
    /// One rule that emits this code.
    struct Rule: Equatable {
        /// The condition, trimmed, for display.
        let condition: String
        /// What follows the code inside the brackets, such as `resolution 24 continue`.
        let tail: String
        /// The rule verbatim, spacing included, spanning both lines where the condition and
        /// its type are written apart. A reassignment substitutes on exactly this text.
        let raw: String
    }

    let kind: MapElementKind
    let code: Int

    /// Every rule emitting this code, in file order.
    let rules: [Rule]

    /// The condition text of each, for display.
    var conditions: [String] { rules.map(\.condition) }

    /// `key=value` pairs distilled from those conditions, deduplicated, in first-seen order.
    /// Several are usual: one code is reached by several rules.
    let tags: [String]

    var hex: String { TypeMeaning.hex(code) }

    /// Lowercase `0x...`, padded to two digits below 0x100 and four above, as both the rule
    /// files and the TYP source write it.
    static func hex(_ code: Int) -> String {
        String(format: code > 0xFF ? "0x%04x" : "0x%02x", code)
    }
}
