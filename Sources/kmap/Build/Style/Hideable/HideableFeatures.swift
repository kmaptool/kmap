import Foundation

/// Something that can be left off the map.
///
/// Hiding works on the rule set, not the data: the rule that draws the feature is
/// commented out, and a rebuild without the id brings it back. Where a rule also carries
/// routing effects, its actions are kept and only the Garmin type is dropped.
struct HideableFeature: Equatable {
    let id: String
    let name: String
    let category: String

    /// The name and category in the interface language. Held apart from `name` and
    /// `category`, which are the catalogue's own text and never change with the language.
    var localizedName: String { HideableNames.name(id: id, english: name) }
    var localizedCategory: String { HideableNames.category(category) }
    /// What hiding this costs, where that is worth stating. May be empty.
    let note: String
    /// The OSM tag this stands for, as `key=value`, so the same choice can be applied to
    /// the custom-POI file.
    let tag: String?
    /// Exact lines from mkgmap's own style, and what to replace them with.
    let substitutions: [(file: String, old: String, new: String)]

    static func == (a: HideableFeature, b: HideableFeature) -> Bool { a.id == b.id }

    // MARK: Catalogue

    /// Hand-written entries for rules the generator cannot express: those spanning several
    /// lines, or whose actions must survive the type being dropped.
    private static let curated: [HideableFeature] = [
        contextual(id: "barriers-fence",
                   name: "Gates in fences and walls around plots",
                   note: "somebody's front gate — the bulk of village clutter",
                   context: "fence"),

        contextual(id: "barriers-minor",
                   name: "Gates on drives and service roads",
                   note: "the drive itself is mapped as a road",
                   context: "minor"),

        contextual(id: "barriers-path",
                   name: "Barriers on paths and tracks",
                   note: "a gate here may be locked — usually worth keeping",
                   context: "path"),

        contextual(id: "barriers-other",
                   name: "Barriers elsewhere",
                   note: "on major roads, or standing on no way at all",
                   context: nil)
    ]

    /// Barriers split by the kind of way they stand on. The rule text has to match the
    /// three-way split `StyleCatalog.splitBarrierRule` writes, byte for byte.
    private static func contextual(id: String, name: String, note: String,
                                   context: String?) -> HideableFeature {
        let barriers = "barrier=bollard | barrier=bus_trap | barrier=gate | barrier=block | "
                     + "barrier=cycle_barrier | barrier=stile | barrier=kissing_gate | "
                     + "barrier=lift_gate | barrier=swing_gate"
        let condition = context.map { "(\(barriers)) & kmap:on=\($0)" }
            ?? "(\(barriers)) & kmap:on!=path & kmap:on!=minor & kmap:on!=fence"
        let action = "    {add name='${barrier|subst:\"_=> \"}'} [0x3200 resolution 24]"
        let hiddenAction = "    {add name='${barrier|subst:\"_=> \"}'}"
                         + "  # kmap: hidden — actions kept, type dropped"
        return HideableFeature(
            id: id, name: name, category: "Barriers and gates", note: note,
            // The .gpi carries no notion of which way a barrier stands on, so any barrier
            // choice drops barriers from it wholesale.
            tag: "barrier=*",
            substitutions: [(file: "points",
                             old: condition + "\n" + action,
                             new: condition + "\n" + hiddenAction)])
    }

    /// The curated entries plus the generated catalogue. Parsed once and cached, and
    /// dropped by `forget` when a style writes a new catalogue.
    static var all: [HideableFeature] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = curated + parseCatalogue(HideableCatalogue.text())
        cached = made
        return made
    }

    private static let lock = NSLock()
    private static var cached: [HideableFeature]?

    static func forget() {
        lock.lock(); cached = nil; lock.unlock()
    }

    static func feature(id: String) -> HideableFeature? {
        all.first { $0.id == id }
    }

    /// Category order as it appears in the catalogue, curated entries first.
    static var categories: [String] {
        var seen: [String] = []
        for feature in all where !seen.contains(feature.category) {
            seen.append(feature.category)
        }
        return seen
    }

    // MARK: Parsing

    private static func parseCatalogue(_ text: String) -> [HideableFeature] {
        var out: [HideableFeature] = []
        var category = "Other"
        var pendingID: String?
        var pendingName: String?
        var pendingTag: String?
        var pendingRules: [(String, String, String)] = []

        func flush() {
            guard let id = pendingID, let name = pendingName, !pendingRules.isEmpty else { return }
            out.append(HideableFeature(id: id, name: name, category: category,
                                       note: "", tag: pendingTag,
                                       substitutions: pendingRules))
            pendingID = nil; pendingName = nil; pendingTag = nil; pendingRules = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@ ") {
                flush()
                category = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                flush()
                pendingID = String(line[line.index(after: line.startIndex)..<close])
                pendingName = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("tag: ") {
                pendingTag = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("points: ") {
                let rule = String(line.dropFirst("points: ".count))
                pendingRules.append(("points", rule, "# " + rule + "  # kmap: hidden"))
            }
        }
        flush()
        return out
    }
}
