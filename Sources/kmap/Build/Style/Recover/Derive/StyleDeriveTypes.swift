import Foundation

extension StyleRecovery {
    /// One meaning, as the default rules see it, and the witnesses a foreign code
    /// gave it. Keyed per rule rather than per tag: two tags that open one rule are
    /// one meaning. A meaning with no rule keeps its tag as its own key.
    struct MeaningBucket {
        var lines: [DefaultRuleBook.Line]
        var tags: [String: Int] = [:]
        /// How many of this meaning's witnesses were seen at each zoom, so a ladder is
        /// read per zoom: one meaning, one stroke at a time.
        var resolutions: [Int: Int] = [:]
        /// The witnesses themselves: shared elements make two codes two layers of
        /// one drawing rather than two kinds.
        var ids: Set<Int64> = []
        var count: Int { ids.count }
        /// How many of them carry `building=*`: a substation building and a
        /// substation yard share a tag, and a style may draw them apart.
        var built = 0
        var isBuilt: Bool { built * 2 > count }
        /// The commonest tag in it: what the report shows, and what a rule written
        /// for it is written from.
        var name: String {
            tags.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
    }

    /// What one foreign code's witnesses meant, before anything has been decided.
    struct CodeReading {
        let key: String
        let code: Evidence.ForCode
        let buckets: [String: MeaningBucket]
        /// Witnesses that meant anything at all.
        let meant: Int
        /// Whether the code is absent from the default rules. A default code writes
        /// nothing to the sheet, but its witnesses still count towards which code
        /// owns a meaning.
        let foreign: Bool

        /// The noise floor for this code: below it a meaning is a side-tag, not a claim.
        var floor: Int { max(fewestWitnesses, Int(Double(meant) * noise)) }
    }

    /// One rule line, and every foreign code laying claim to it. A style painting a
    /// road as casing, fill and a low-zoom stroke has three codes for one rule, and
    /// all three belong in the sheet as layers.
    struct ClaimedRule {
        let lines: [DefaultRuleBook.Line]
        var codes:
            [(
                type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                resolutions: [Int: Int]
            )] = []
    }

    /// A rule the style does not have, to be written for a code that needs one.
    struct RuleAddition {
        let tag: String
        let key: String
        let type: Int
        let witnesses: Int
        /// The elements it was seen on: for one tag, the same elements are two
        /// layers and different ones are two kinds.
        let ids: Set<Int64>
        /// The zooms the code was seen drawn at, so a rule written for it draws
        /// where its author drew it rather than at every zoom below.
        var resolutions: [Int: Int] = [:]
        /// Written with `& building!=*`: their map draws the buildings carrying this
        /// tag as buildings, and only the open ground this way.
        var openOnly = false
    }

    /// What resolving one code decided, kept for the silencing pass: whether any chosen
    /// meaning already emits the code - the two vocabularies agreeing on the number -
    /// and the words for the comment when they do not.
    struct CodeVerdict {
        let agrees: Bool
        let meaning: String
    }
}
