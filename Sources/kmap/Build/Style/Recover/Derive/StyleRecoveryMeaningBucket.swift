import Foundation

extension StyleRecovery {
    /// One meaning, as the default rules see it, and the witnesses a foreign code
    /// gave it. Keyed per rule rather than per tag: 2 tags that open 1 rule are
    /// one meaning. A meaning with no rule keeps its tag as its own key.
    struct MeaningBucket {
        var lines: [DefaultRuleBook.Line]
        var tags: [String: Int] = [:]
        /// How many of this meaning's witnesses were seen at each zoom, so a ladder is
        /// read per zoom: one meaning, one stroke at a time.
        var resolutions: [Int: Int] = [:]
        /// The witnesses themselves: shared elements make 2 codes 2 layers of
        /// 1 drawing rather than 2 kinds.
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
}
