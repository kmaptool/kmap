import Foundation

/// Porting a borrowed look onto kmap's own numbers.
///
/// A Garmin number means nothing by itself, so numbers stay where they are and the
/// drawing travels: their picture for a forest onto our number for a forest. Which
/// picture belongs to which number is decided by the evidence - what each side was seen
/// drawing a meaning with. What their style never drew stays unpainted.
enum StylePort {
    /// Their code for every one of our codes the evidence can speak for. Where both
    /// sides draw a meaning at several zooms the rungs are paired by zoom, closest
    /// first; neither side's numbering is consulted.
    ///
    /// - Parameters:
    ///   - codesByTag: what their map was seen drawing each meaning with.
    ///   - rules: kmap's own rule set, which says what our numbers mean.
    ///   - theirZooms: the zooms each of their codes was seen drawn at.
    ///   - theirAreas: the ground each meaning covers under each of their codes. A
    ///     number of ours shared by two meanings wears the picture of the one covering
    ///     more: fields are few and wide, lawns many and small.
    static func map(
        codesByTag: [String: [String: Int]],
        rules: RuleSetIndex,
        theirZooms: [String: [Int: Int]] = [:],
        theirTyp: TypSource? = nil,
        theirAreas: [String: [String: Double]] = [:]
    ) -> [Ported] {
        let ourCodes = ourNumbers(in: rules)
        let theirs = theirLadders(
            codesByTag: codesByTag,
            ourCodes: ourCodes,
            theirZooms: theirZooms,
            theirTyp: theirTyp,
            theirAreas: theirAreas
        )
        var seen: [String: Int] = [:]
        for drawn in codesByTag.values {
            for (key, count) in drawn { seen[key, default: 0] += count }
        }
        let offered = offers(
            theirs: theirs,
            ourCodes: ourCodes,
            ourFinest: ourReach(in: rules),
            theirTyp: theirTyp,
            seen: seen
        )
        var claimed = claim(offered, agreement: Agreement(codesByTag: codesByTag, ourCodes: ourCodes), seen: seen)
        lendPictures(to: &claimed, rules: rules)
        let ported = claimed.values.flatMap(\.values).sorted {
            ($0.kind.rawValue, $0.ours) < ($1.kind.rawValue, $1.ours)
        }
        return ordered(ported, ranks: LineDrawOrder.ranks(in: rules), theirs: theirTyp)
    }

    /// What mkgmap manufactures rather than reads, and the number of theirs each takes
    /// its picture from. Contours, sea and the background are mkgmap's own on both
    /// sides, so there the number is the shared name. Land is not: kmap draws it on
    /// 0x27, where a borrowed style may keep a construction site, so it takes the paper
    /// the map is printed on - their background.
    static let generatedTypes: [(kind: MapElementKind, ours: Int, theirs: Int)] = [
        (.line, 0x20, 0x20), (.line, 0x21, 0x21), (.line, 0x22, 0x22),
        (.polygon, seaCode, seaCode), (.polygon, 0x4a, 0x4a),
        (.polygon, backgroundCode, backgroundCode),
        (.polygon, 0x27, backgroundCode)
    ]

    /// Whether a port lands on one of those numbers, which the TYP draws from the ground
    /// sections and never from the port.
    static func landsOnGround(_ port: Ported) -> Bool {
        generatedTypes.contains { $0.kind == port.kind && $0.ours == port.ours }
    }

    /// The ports the TYP draws: one on a ground number takes the ground's section.
    static func drawn(_ ported: [Ported]) -> [Ported] { ported.filter { !landsOnGround($0) } }

    /// The sea and the background, the two grounds with a level of their own.
    static let seaCode = 0x32
    static let backgroundCode = 0x4b

    /// A rule with no band, in the ladder's own units: further in than any zoom.
    static let everyZoom = 100

    /// The line a ported palette carries to say it was written for kmap's numbers, and
    /// that what it does not paint is meant to stay undrawn.
    static let forOurNumbers = "kmap:for-kmap-numbers"

    /// Below this a picture is a coincidence, not a look their style keeps.
    static let fewestToPort = 3

    /// What a rung must hold against the meaning's best-attested picture to count as one
    /// of its zooms rather than as a stray identification.
    static let rungShare = 0.1

    /// How much of everything one of their numbers drew has to be this meaning for the
    /// picture to be the meaning's own rather than the ground it happened to lie on.
    /// A nature reserve is drawn over forest, so their forest was seen inside 30 or so
    /// reserve outlines - a fraction of a percent of the forest they drew.
    static let strayShare = 0.02

    /// How often a picture below that share must still have been seen to be believed:
    /// a garden really is drawn as a park, 5 fords under a marker are not.
    static let fewestIfStray = 50

    /// The evidence's key for a code of theirs, the form `theirZooms` is keyed by.
    static func key(_ kind: MapElementKind, _ code: Int) -> String {
        switch kind {
        case .line: return "L" + String(code, radix: 16)
        case .polygon: return "A" + String(code, radix: 16)
        case .point: return "P" + String(code, radix: 16)
        }
    }

    /// `L11f14` and the like, as the evidence keys codes.
    static func read(_ key: String) -> (MapElementKind, Int)? {
        guard let first = key.first, let code = Int(key.dropFirst(), radix: 16)
        else { return nil }
        switch first {
        case "L": return (.line, code)
        case "A": return (.polygon, code)
        case "P": return (.point, code)
        default: return nil
        }
    }
}
