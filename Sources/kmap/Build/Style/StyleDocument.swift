import Foundation

/// How a style's TYP can be got at.
enum TypAvailability: Equatable {
    /// An mkgmap `.txt` TYP: readable, and editable in place.
    case source
    /// A compiled `.typ`. Its identity can be read; its contents need a decoder of kmap's
    /// own, since mkgmap compiles in one direction only.
    case binary
    /// The style draws with whatever the device decides.
    case none
}

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

    /// The tags that reach this code — this style's own, or the default set's where
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

    /// What the tag column shows: the rules' tags, or — where no rule names the code —
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
        guard section?.englishLabel?.isEmpty == false
            || section?.russianLabel?.isEmpty == false else { return "" }
        return GarminStandard.meaning(kind, code, russian: russian) ?? ""
    }

    /// How many distinct meanings share this code; more than one means one drawing has to
    /// serve them all.
    var meaningCount: Int { tags.count }
}

/// Everything the editor can read about one style, gathered in one place.
///
/// Read-only. `TypSource` holds the file verbatim, so a later editing pass has an exact
/// original to work from rather than a reconstruction.
struct StyleDocument {
    let style: MapStyle
    let availability: TypAvailability

    /// The TYP source, where the style has one in readable form.
    let source: TypSource?

    /// The rule set a build would use with this style.
    let rules: RuleSetIndex?

    /// Where the source was read from, for showing on screen.
    let sourceURL: URL?

    // MARK: Loading

    /// The default rule set, read once per process: the reference vocabulary every
    /// style's list is completed against.
    private static let referenceRules =
        RuleSetIndex.read(styleDirectory: StyleCatalog.baseStyleDirectory)
            ?? RuleSetIndex()

    /// Reads what can be read. Never throws and never writes: a style whose TYP is binary
    /// or missing still produces a document, just a thinner one.
    static func load(_ style: MapStyle) -> StyleDocument {
        let rules = RuleSetIndex.read(styleDirectory: style.styleDirectory
            ?? StyleCatalog.baseStyleDirectory)

        guard let typURL = style.typURL else {
            return StyleDocument(style: style, availability: .none, source: nil,
                                 rules: rules, sourceURL: nil)
        }

        if typURL.pathExtension.lowercased() == "txt" {
            guard let source = TypSource.read(typURL) else {
                return StyleDocument(style: style, availability: .none, source: nil,
                                     rules: rules, sourceURL: typURL)
            }
            return StyleDocument(style: style, availability: .source, source: source,
                                 rules: rules, sourceURL: typURL)
        }

        return StyleDocument(style: style, availability: .binary, source: nil,
                             rules: rules, sourceURL: typURL)
    }

    // MARK: What is in it

    var familyID: Int { source?.familyID ?? style.familyID }
    var productID: Int { source?.productID ?? style.productID }
    var codePage: Int? { source?.codePage }

    /// Whether the TYP's contents can be read at all. False for a compiled file.
    var isReadable: Bool { source != nil }

    /// Whether an edit made here would survive. A built-in style's working copy under
    /// `~/.kmap/styles` reads, but is rewritten from the embedded palette on the next
    /// build, so editing one means taking a copy into the library first.
    var isEditable: Bool {
        guard source != nil, let url = sourceURL else { return false }
        return TypLibrary.mayWrite(to: url)
    }

    /// Every code either side knows about — and every free plain code of the kind's
    /// space, so the list is also the menu of what can still be drawn and assigned.
    /// Extended codes are not enumerated: there are thousands, and the add-section
    /// command takes any code by hand.
    func rows(_ kind: MapElementKind, russian: Bool = false) -> [StyleTypeRow] {
        let emitted = rules?.codes(kind) ?? []
        let styled = source?.codes(kind) ?? []
        var codes = emitted.union(styled)
        // The reference vocabulary completes the list: a meaning this style's rules
        // dropped is still shown, for the user to bring back or restyle.
        codes.formUnion(Self.referenceRules.codes(kind))
        switch kind {
        case .line:
            codes.formUnion(0x01...0x3f)
        case .polygon:
            codes.formUnion(0x01...0x7f)
        case .point:
            // Points carry a subtype; a free row is offered per type byte, and only
            // where no subtype of that type is in use on either side.
            let usedTypes = Set(codes.map { $0 > 0xFF ? $0 >> 8 : $0 })
            for type in 0x01...0x7f where !usedTypes.contains(type) {
                codes.insert(type << 8)
            }
        }
        return codes.sorted().map { code in
            StyleTypeRow(kind: kind, code: code,
                         meaning: rules?.meaning(kind, code),
                         reference: Self.referenceRules.meaning(kind, code),
                         section: source?.section(kind, code))
        }
    }

    /// The split between what the map emits and what the TYP draws.
    struct Coverage {
        let kind: MapElementKind
        let both: Int
        /// Emitted by the rules, absent from the TYP, and nothing says that is on purpose.
        /// The device draws its own idea of these.
        let unstyled: [Int]
        /// Absent from the TYP and marked as deliberately so. Not a gap.
        let deliberate: [Int]
        /// Styled by the TYP, never emitted — weight in the file with nothing to draw on.
        let unused: [Int]

        var emitted: Int { both + unstyled.count + deliberate.count }
        var styled: Int { both + unused.count }
    }

    func coverage(_ kind: MapElementKind) -> Coverage {
        let emitted = rules?.codes(kind) ?? []
        let styled = source?.codes(kind) ?? []
        let intended = source?.deliberatelyUnstyled[kind] ?? []
        let missing = emitted.subtracting(styled)
        return Coverage(kind: kind,
                        both: emitted.intersection(styled).count,
                        unstyled: missing.subtracting(intended).sorted(),
                        deliberate: missing.intersection(intended).sorted(),
                        unused: styled.subtracting(emitted).sorted())
    }

    /// Whether the file says this type is left to the device on purpose.
    func isDeliberatelyUnstyled(_ kind: MapElementKind, _ code: Int) -> Bool {
        source?.deliberatelyUnstyled[kind]?.contains(code) ?? false
    }

    /// Codes the TYP styles and the draw order forgets. Polygons only — a polygon missing
    /// from `[_drawOrder]` is not drawn at all, and nothing on screen says so.
    var polygonsNeverDrawn: [Int] { source?.polygonsMissingFromDrawOrder ?? [] }
}
