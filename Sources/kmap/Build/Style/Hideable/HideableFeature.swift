import Foundation

/// Something that can be left off the map.
///
/// Hiding works on the rule set, not the data: the rule that draws the feature loses its
/// type, and a rebuild without the id brings it back. Its actions are kept, and its keys
/// are deleted, so the object stops there rather than being drawn by a catch-all below.
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
        contextual(
            id: "barriers-fence",
            name: "Gates in fences and walls around plots",
            note: "somebody's front gate — the bulk of village clutter",
            context: "fence"
        ),

        contextual(
            id: "barriers-minor",
            name: "Gates on drives and service roads",
            note: "the drive itself is mapped as a road",
            context: "minor"
        ),

        contextual(
            id: "barriers-path",
            name: "Barriers on paths and tracks",
            note: "a gate here may be locked — usually worth keeping",
            context: "path"
        ),

        contextual(
            id: "barriers-other",
            name: "Barriers elsewhere",
            note: "on major roads, or standing on no way at all",
            context: nil
        )
    ]

    /// Barriers split by the kind of way they stand on: one substitution per group,
    /// each naming the line `StyleCatalog.splitBarrierRule` writes, byte for byte,
    /// from the same definitions.
    private static func contextual(
        id: String,
        name: String,
        note: String,
        context: String?
    ) -> HideableFeature {
        let hiddenAction =
            "    {add name='${barrier|subst:\"_=> \"}'}"
            + "  # kmap: hidden — actions kept, type dropped"
        return HideableFeature(
            id: id,
            name: name,
            category: "Barriers and gates",
            note: note,
            // The .gpi carries no notion of which way a barrier stands on, so any barrier
            // choice drops barriers from it wholesale.
            tag: "barrier=*",
            substitutions: StyleCatalog.barrierGroups.map { group in
                let condition = StyleCatalog.barrierCondition(group.barriers, context: context)
                return (
                    file: "points",
                    old: condition + "\n" + StyleCatalog.barrierAction(code: group.code),
                    new: condition + "\n" + hiddenAction
                )
            }
        )
    }

    /// The curated entries plus the generated catalogue. Parsed once and cached, and
    /// dropped by `forget` when a style writes a new catalogue.
    static var all: [HideableFeature] {
        cached.withLock { held in
            if let held { return held }
            let made = curated + parseCatalogue(HideableCatalogue.text())
            held = made
            return made
        }
    }

    private static let cached = Locked<[HideableFeature]?>(nil)

    static func forget() {
        cached.withLock { $0 = nil }
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

    /// Keys that say what a place has rather than what it is.
    static let featureKeys: Set<String> = ["internet_access"]

    /// A generated entry's rule with its type dropped and the entry's key deleted, so
    /// `shop=* & name=*` below does not draw a hidden shop as a generic one, nor a `cuisine`
    /// rule a hidden cafe as a restaurant. Only that key and `cuisine`: a node that is also
    /// something else keeps the tags that draw it. Label actions go too, or a hidden peak's
    /// name would label the viewpoint on the same node. A rule it cannot read is commented out.
    static func hidden(_ rule: String, tag: String? = nil) -> String {
        guard let open = rule.range(of: "[0x") else { return "# " + rule + "  # kmap: hidden" }
        var head = String(rule[rule.startIndex..<open.lowerBound])
        while head.last == " " { head.removeLast() }
        var condition = head
        var actions: [String] = []
        if let brace = head.firstIndex(of: "{"), let close = head.lastIndex(of: "}"), brace < close {
            condition = String(head[head.startIndex..<brace])
            actions = Self.actions(in: String(head[head.index(after: brace)..<close]))
                .filter { !Self.setsLabel($0) }
        }
        while condition.last == " " { condition.removeLast() }
        // The entry's key, and any other key the condition tests for the same value, as
        // `amenity=border_control | barrier=border_control`.
        let pairs = condition.allMatches("[A-Za-z_:]+=[A-Za-z0-9_:.-]+").map { $0.components(separatedBy: "=") }
        let wanted = tag?.components(separatedBy: "=") ?? pairs.first ?? []
        var keys = wanted.first.map { [$0] } ?? []
        if wanted.count == 2 {
            keys += pairs.filter { $0.count == 2 && $0[1] == wanted[1] }.map { $0[0] }
        }
        // Not for a hidden feature of a place, as its Wi-Fi: the place itself is drawn by
        // its own rules, a pizzeria still a pizzeria.
        if let key = wanted.first, !Self.featureKeys.contains(key) { keys.append("cuisine") }
        for removal in keys.map({ "delete \($0)" }) where !actions.contains(removal) {
            actions.append(removal)
        }
        return condition + " {" + actions.joined(separator: "; ") + "}  # kmap: hidden"
    }

    /// The statements of an action block, split on `;` outside quotes and `${tag}`.
    private static func actions(in block: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for c in block {
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
            } else if c == ";", depth == 0 {
                out.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether a statement writes the label rather than a tag a later rule reads.
    private static func setsLabel(_ statement: String) -> Bool {
        statement.hasPrefix("name ") || statement.hasPrefix("name'")
            || statement.hasPrefix("add name=") || statement.hasPrefix("set name=")
            || statement.hasPrefix("add mkgmap:label") || statement.hasPrefix("set mkgmap:label")
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
            out.append(
                HideableFeature(
                    id: id,
                    name: name,
                    category: category,
                    note: "",
                    tag: pendingTag,
                    substitutions: pendingRules
                )
            )
            pendingID = nil; pendingName = nil; pendingTag = nil; pendingRules = []
        }

        for line in TextLines.of(text) {
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
                pendingRules.append(("points", rule, hidden(rule, tag: pendingTag)))
            }
        }
        flush()
        return out
    }
}
