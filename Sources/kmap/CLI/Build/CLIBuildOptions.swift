import Foundation

/// The build options `kmap build` and `kmap profiles new|set` share, read from the flags
/// with every refusal collected, so one run reports everything wrong with it before any
/// download. Out of range is refused rather than clamped; a word nothing answers to is
/// refused rather than swapped for a default.
extension CLI {
    struct BuildOptions {
        let flags: Flags
        /// Every unreadable flag lands here; the build is refused while it is not empty.
        var refused: [String] = []

        init(_ flags: Flags) { self.flags = flags }

        // MARK: What a flag may say

        static let heapGB = 1...512
        static let memoryGB = 1...4096
        static let connections = 1...PartFiles.maxParts
        static let parts = 1...64
        static let contourInterval = 1...1000
        static let nodesPerTile = 100_000...20_000_000
        static let familyID = 1...65535
        static let overlap = 0...BuildChoices.overlapCeiling
        static let repairRadiusMetres = 0.0...50.0
        /// The words `--split` takes, in the spelling `SplitMode.settingsID` stores.
        static let splitModes = ["fit", "region", "country", "custom"]
        /// The kebab-case spelling the help text gives `DescriptionCarrier.inName`.
        static let inNameSpelling = "in-name"

        // MARK: Reading

        /// A switch either flag can move: `--no-dem` off, `--dem` on, else `current`.
        func switched(_ name: String, _ current: Bool) -> Bool {
            if flags.has("no-" + name) { return false }
            if flags.has(name) { return true }
            return current
        }

        /// `--word-index` / `--no-word-index`; `--lean-index` is the retired spelling of
        /// the negative, still accepted.
        func wordIndex(_ current: Bool) -> Bool {
            flags.has("lean-index") ? false : switched("word-index", current)
        }

        /// A number a flag carries, or nil where the flag is absent.
        mutating func number(_ name: String, in range: ClosedRange<Int>) -> Int? {
            guard let raw = flags.value(name) else { return nil }
            guard let value = Int(raw) else {
                refused.append("--\(name)=\(raw) is not a number")
                return nil
            }
            guard range.contains(value) else {
                refused.append(
                    "--\(name)=\(value) is outside \(range.lowerBound)-\(range.upperBound)"
                )
                return nil
            }
            return value
        }

        /// One of a known set of words, matched without regard to case, or nil where the
        /// flag is absent.
        mutating func word<T>(_ name: String, among options: [(id: String, value: T)]) -> T? {
            guard let raw = flags.value(name) else { return nil }
            if let match = options.first(where: { $0.id.caseInsensitiveCompare(raw) == .orderedSame }) {
                return match.value
            }
            refused.append("--\(name)=\(raw) — one of " + options.map(\.id).joined(separator: ", "))
            return nil
        }

        /// The same, answering with the word as the option spells it.
        mutating func word(_ name: String, among options: [String]) -> String? {
            word(name, among: options.map { ($0, $0) })
        }

        /// `--repair-radius`: metres, within reason.
        mutating func repairRadius() -> Double? {
            guard let raw = flags.value("repair-radius") else { return nil }
            guard let value = Double(raw), Self.repairRadiusMetres.contains(value) else {
                refused.append(
                    "--repair-radius=\(raw) wants metres, \(Int(Self.repairRadiusMetres.lowerBound))"
                        + " to \(Int(Self.repairRadiusMetres.upperBound))"
                )
                return nil
            }
            return value
        }

        /// `--code-page`: a number, or `auto` (and the 0 that stands for it), which hands
        /// the code page back to the region. Zero must not reach mkgmap.
        mutating func codePage() -> Int? {
            guard let raw = flags.value("code-page") else { return nil }
            if raw.caseInsensitiveCompare("auto") == .orderedSame || raw == "0" { return 0 }
            if let value = Int(raw), value > 0 { return value }
            refused.append("--code-page=\(raw) — a number, or auto for the region's own")
            return nil
        }

        /// `--descriptions[=carrier]`: bare, the phone line. Nil where the flag is absent.
        mutating func descriptions() -> BuildRecipe.DescriptionCarrier? {
            guard flags.has("descriptions") else { return nil }
            guard flags.value("descriptions") != nil else { return .phone }
            let carriers =
                BuildRecipe.DescriptionCarrier.allCases.map { ($0.rawValue, $0) }
                + [(Self.inNameSpelling, BuildRecipe.DescriptionCarrier.inName)]
            return word("descriptions", among: carriers)
        }

        /// `--hide=a,b`: the ids to leave off the map; `--hide=` with nothing after it is
        /// an empty list. Nil where the flag is absent; an id nothing answers to is refused.
        mutating func hidden() -> [String]? {
            guard let asked = flags.value("hide") else { return nil }
            let ids =
                asked.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let unknown = ids.filter { HideableFeature.feature(id: $0) == nil }
            guard unknown.isEmpty else {
                refused.append(
                    "unknown --hide id(s): \(unknown.joined(separator: ", ")) — see `kmap hideable`"
                )
                return nil
            }
            return ids
        }

        /// `--style`: a style the catalog knows, or nil where the flag is absent.
        mutating func style(in catalog: StyleCatalog) -> MapStyle? {
            guard let id = flags.value("style") else { return nil }
            if let found = catalog.availableStyles().first(where: { $0.id == id }) { return found }
            refused.append("--style=\(id) is not a style kmap can find — see `kmap styles`")
            return nil
        }

        /// `--zoom-plan=<name>`: matched by name among the plans made for the ladder, the
        /// built-in included. Nil where the flag is absent.
        mutating func zoomPlan(forLadder levelsID: String, in settings: Settings) -> ZoomPlan? {
            let plans =
                [ZoomPlan.builtin(forLevels: levelsID)]
                + settings.zoomPlans.filter { $0.levelsID == levelsID }
            return word("zoom-plan", among: plans.map { ($0.name, $0) })
        }
    }
}
