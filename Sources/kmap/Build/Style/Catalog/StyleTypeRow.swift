import Foundation

/// One type code as the editor needs to show it: what it means, and how it is drawn.
///
/// Either half can be missing. A code the rules emit but the TYP does not style falls back
/// to the device's own idea of it; a code styled and never emitted is weight in the file.
struct StyleTypeRow {
    let kind: MapElementKind
    let code: Int

    /// What the rule set says this code means, in OSM terms.
    let meaning: TypeMeaning?
    /// What the DEFAULT rule set would mean by it, where this style's rules are
    /// silent: the whole vocabulary is on the table, and the user decides what to
    /// draw. A ferry exists whether or not this particular style sends one.
    let reference: TypeMeaning?
    /// How the TYP draws it.
    let section: TypSection?

    var hex: String { TypeMeaning.hex(code) }
    var isEmitted: Bool { meaning != nil }
    var isStyled: Bool { section != nil }

    /// The tags that reach this code - this style's own, or the default set's where
    /// this style is silent. Several is the normal case.
    var tags: [String] { meaning?.tags ?? reference?.tags ?? [] }

    /// The colour this type reads as by day and by night, for a list with room for two
    /// blocks and not for a palette. Night is nil where the file says nothing about it.
    var representativeColours: (day: String?, night: String?) {
        section?.representativeColours ?? (nil, nil)
    }

    /// The best short name available, preferring what the device itself would print:
    /// the TYP's own `String=`, then the OSM tag, then the code's conventional Garmin
    /// meaning, then the number.
    func name(preferringRussian russian: Bool) -> String {
        if let section {
            if russian, let label = section.russianLabel, !label.isEmpty { return label }
            if let label = section.englishLabel, !label.isEmpty { return label }
        }
        // The universal vocabulary, where it names this exact code: the same words in
        // every style, so eight ladder rows all tagged place=city read apart.
        if let universal = GarminStandard.exactMeaning(kind, code, russian: russian) {
            return universal
        }
        if let first = tags.first { return first }
        if let standard = GarminStandard.meaning(kind, code, russian: russian) {
            return standard
        }
        return hex
    }

    /// What the tag column shows: the rules' tags, or - where no rule names the code -
    /// its conventional Garmin meaning. Never a repeat of the name column: a row that
    /// says the same thing twice says it no better.
    func tagColumn(preferringRussian russian: Bool) -> String {
        let shown = name(preferringRussian: russian)
        if !tags.isEmpty {
            let rest = tags.first == shown ? Array(tags.dropFirst()) : tags
            return rest.joined(separator: ", ")
        }
        // The convention is a hint beside a TYP's own label; with no label the name
        // column is already the convention.
        guard
            section?.englishLabel?.isEmpty == false
                || section?.russianLabel?.isEmpty == false
        else { return "" }
        return GarminStandard.meaning(kind, code, russian: russian) ?? ""
    }

    /// How many distinct meanings share this code; more than one means one drawing has to
    /// serve them all.
    var meaningCount: Int { tags.count }
}
