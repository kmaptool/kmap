import Foundation

/// Porting a borrowed look onto kmap's own numbers.
///
/// A Garmin number means nothing by itself, so numbers stay where they are and the
/// drawing travels: their picture for a forest onto our number for a forest. Which
/// picture belongs to which number is decided by the evidence — what each side was seen
/// drawing a meaning with. What their style never drew stays unpainted.
enum StylePort {

    /// One porting: their code, and how sure the evidence is.
    struct Ported {
        let ours: Int
        let theirs: Int
        let kind: MapElementKind
        /// The meaning both sides were seen drawing, for the report.
        let meaning: String
        /// How many of their elements were identified as that meaning.
        let witnesses: Int
        /// How wide the line is drawn, where that is not the picture's own width: a
        /// number of ours drawn at every zoom wears the far rung's width and the near
        /// rung's paint, and no road is wider than one above it in the hierarchy.
        let width: Int?
        /// What settles a number two meanings share: the ground covered for a fill,
        /// the sightings for anything else.
        var weight: Double = 0
        /// The other looks that wanted this number and lost: one number of ours for
        /// several things of theirs, which is where a look goes wrong.
        var rivals: [Rival] = []
    }

    /// A look that lost a number of ours to another meaning.
    struct Rival {
        let theirs: Int
        let meaning: String
        let witnesses: Int
    }

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
    static func map(codesByTag: [String: [String: Int]],
                    rules: RuleSetIndex,
                    theirZooms: [String: [Int: Int]] = [:],
                    theirTyp: TypSource? = nil,
                    theirAreas: [String: [String: Double]] = [:]) -> [Ported] {
        // Our side: meaning -> the numbers kmap draws it with, and the closest zoom each
        // of them is drawn at, so our own ladder can be read the same way as theirs.
        let ourCodes = ourNumbers(in: rules)
        var ourFinest: [MapElementKind: [Int: Int]] = [:]
        for kind in MapElementKind.allCases {
            for meaning in rules.byKind[kind]?.values ?? [:].values {
                // A rule with no band draws at every zoom and is the closest picture
                // of the meaning; a rung is pinned to a band and belongs further out.
                // Ranked so the bandless comes first, then by how close its band is.
                let reach = meaning.rules.map { rung(of: $0.tail) }
                    .min { ($0.banded ? 1 : 0, -$0.finest) < ($1.banded ? 1 : 0, -$1.finest) }
                let held = ourFinest[kind]?[meaning.code] ?? 0
                // The furthest reach wins, whichever meaning is read first: one code can
                // be emitted by several meanings, and a dictionary hands them over in a
                // different order in every process.
                ourFinest[kind, default: [:]][meaning.code] =
                    max(held, (reach?.banded == false) ? everyZoom
                              : (reach?.finest ?? GarminGrid.fullResolution))
            }
        }

        // Their side: meaning -> every number that drew it, with how much and at which
        // zooms, so a ladder can be told from a single picture. A rule of ours written
        // for a whole key, `building=*`, is answered by what their map drew for the
        // values of that key no rule of ours names: a hotel never reaches the
        // `tourism=*` fallback, so their hotel is no answer for it.

        var theirs: [MapElementKind: [String: [(code: Int, count: Int, finest: Int,
                                               area: Double)]]] = [:]
        for (tag, drawn) in codesByTag {
            let family = tag.split(separator: "=").first.map { $0 + "=*" }
            for (key, count) in drawn where count >= fewestToPort {
                guard let (kind, code) = read(key) else { continue }
                // A number their style leaves blank carries no look: it must not take a
                // rung of the ladder and leave the picture below it homeless. A point
                // is no rung, and a blank icon is a look of its own: the name alone.
                if let theirTyp {
                    let section = theirTyp.section(kind, code)
                    if section == nil || (kind != .point && !draws(section)) { continue }
                }
                let finest = theirZooms[key]?.keys.max() ?? GarminGrid.fullResolution
                let area = theirAreas[tag]?[key] ?? 0
                theirs[kind, default: [:]][tag, default: []].append((code, count, finest, area))
                if let family, ourCodes[kind]?[tag] == nil {
                    var held = theirs[kind, default: [:]][String(family), default: []]
                    if let at = held.firstIndex(where: { $0.code == code }) {
                        held[at].count += count
                        held[at].area += area
                    } else {
                        held.append((code, count, finest, area))
                    }
                    theirs[kind, default: [:]][String(family)] = held
                }
            }
        }

        // How much of what their number drew is this meaning: a reserve lies on forest,
        // so counting alone would paint our reserves as woodland.
        var seen: [String: Int] = [:]
        for drawn in codesByTag.values {
            for (key, count) in drawn { seen[key, default: 0] += count }
        }
        func stray(_ code: Int, _ kind: MapElementKind, _ count: Int) -> Bool {
            let total = seen[key(kind, code)] ?? count
            return Double(count) < strayShare * Double(max(total, 1))
        }

        // The join, rung by rung, both sides from the closest zoom outward. Walked in
        // the meanings' own order: two can be attested alike, and a dictionary hands
        // them over differently in every run.
        var claimed: [MapElementKind: [Int: Ported]] = [:]
        for kind in MapElementKind.allCases {
            for (tag, drawn) in (theirs[kind] ?? [:]).sorted(by: { $0.key < $1.key }) {
                // A rung has to be a real one: a handful of sightings is the matcher
                // brushing past, and it puts grass on the forest below it.
                let best = drawn.map(\.count).max() ?? 0
                // Both tests: enough of this meaning's sightings to be one of its zooms,
                // and enough of what their number drew to be a picture for it. Their
                // plain marker covers five fords among six thousand places, and a marker
                // is no ford icon — so the ford stays unpainted, as in the original.
                let real = drawn.filter {
                    Double($0.count) >= rungShare * Double(best)
                        && (!stray($0.code, kind, $0.count) || $0.count >= fewestIfStray)
                }
                // The meaning's own ladder, closest zoom first; their code last, so
                // rungs attested alike keep one order between runs.
                let ladder = real.sorted {
                    ($0.finest, $0.count, $0.code) > ($1.finest, $1.count, $1.code)
                }
                guard !ladder.isEmpty else { continue }
                // Ours from the closest zoom outward; between two that draw at every
                // zoom the lower number is the meaning's own, the higher a companion.
                let mine = (ourCodes[kind]?[tag] ?? []).sorted {
                    let a = ourFinest[kind]?[$0] ?? GarminGrid.fullResolution
                    let b = ourFinest[kind]?[$1] ?? GarminGrid.fullResolution
                    return a == b ? $0 < $1 : a > b
                }
                guard !mine.isEmpty else { continue }
                for (at, ours) in mine.enumerated() {
                    // Ours beyond their ladder repeat its coarsest picture rather than
                    // going blank: the road stays visible as it zooms out.
                    let picture = ladder[min(at, ladder.count - 1)]
                    // A line pinned to no band is drawn at every zoom the rule reaches:
                    // the near rung's picture, the far rung's width.
                    let far = ladder.last
                    let spread = kind == .line && ourFinest[kind]?[ours] == everyZoom
                    let width = spread
                        ? [theirTyp?.section(kind, picture.code)?.lineWidth,
                           far.flatMap { theirTyp?.section(kind, $0.code)?.lineWidth }]
                            .compactMap { $0 }.min()
                        : nil
                    // Two meanings on one number of ours: where their code for one of
                    // them IS our number, the two vocabularies agree and that settles
                    // it; then the fill covering more ground, and elsewhere the one
                    // seen more often.
                    let held = claimed[kind, default: [:]][ours]
                    let weight = kind == .polygon && picture.area > 0
                        ? picture.area : Double(picture.count)
                    let mineNow = (picture.code == ours ? 1 : 0,
                                   stray(picture.code, kind, picture.count) ? 0 : 1, weight)
                    let theirsNow = held.map {
                        ($0.theirs == ours ? 1 : 0,
                         stray($0.theirs, kind, $0.witnesses) ? 0 : 1, $0.weight)
                    }
                    // The same look under another tag is no rival: one rule, two names.
                    if let held, held.theirs == picture.code { continue }
                    if theirsNow == nil || mineNow > theirsNow! {
                        var rivals = held?.rivals ?? []
                        if let held {
                            rivals.append(Rival(theirs: held.theirs, meaning: held.meaning,
                                                witnesses: held.witnesses))
                        }
                        claimed[kind, default: [:]][ours] = Ported(
                            ours: ours, theirs: picture.code, kind: kind,
                            meaning: tag, witnesses: picture.count, width: width,
                            weight: weight, rivals: rivals)
                    } else {
                        claimed[kind]?[ours]?.rivals.append(
                            Rival(theirs: picture.code, meaning: tag, witnesses: picture.count))
                    }
                }
            }
        }
        let ported = claimed.values.flatMap(\.values).sorted {
            ($0.kind.rawValue, $0.ours) < ($1.kind.rawValue, $1.ours)
        }
        return ordered(ported, ranks: LineDrawOrder.ranks(in: rules), theirs: theirTyp)
    }

    /// Meaning -> the numbers kmap draws it with, per kind.
    private static func ourNumbers(in rules: RuleSetIndex) -> [MapElementKind: [String: Set<Int>]] {
        var out: [MapElementKind: [String: Set<Int>]] = [:]
        for kind in MapElementKind.allCases {
            for meaning in rules.byKind[kind]?.values ?? [:].values {
                for tag in meaning.tags {
                    out[kind, default: [:]][tag, default: []].insert(meaning.code)
                }
            }
        }
        return out
    }

    /// Our numbers for the meanings their map leaves to the receiver: drawn with a
    /// number their TYP has no section for at all, so the receiver's own glyph is what
    /// their map shows. A bay's name, a town. Declared in the ported TYP, so the build
    /// does not silence the rule for want of a picture.
    static func leftToTheDevice(codesByTag: [String: [String: Int]], rules: RuleSetIndex,
                                theirTyp: TypSource, ported: [Ported])
        -> [MapElementKind: Set<Int>] {
        let ourCodes = ourNumbers(in: rules)
        var painted: [MapElementKind: Set<Int>] = [:]
        for port in ported { painted[port.kind, default: []].insert(port.ours) }
        var out: [MapElementKind: Set<Int>] = [:]
        for (tag, drawn) in codesByTag {
            for (key, count) in drawn where count >= fewestToPort {
                guard let (kind, code) = read(key), theirTyp.section(kind, code) == nil,
                      let ours = ourCodes[kind]?[tag] else { continue }
                for number in ours where painted[kind]?.contains(number) != true {
                    out[kind, default: []].insert(number)
                }
            }
        }
        return out
    }

    /// The road hierarchy kept in the widths: a motorway drawn at every zoom takes a
    /// width the overview can carry, and without this the driveway beside it — drawn
    /// only up close — comes out the wider of the two.
    private static func ordered(_ ported: [Ported], ranks: [Int: Int],
                                theirs: TypSource?) -> [Ported] {
        guard let theirs, !ranks.isEmpty else { return ported }
        var narrowest = Int.max
        var capped: [Int: Int] = [:]
        let roads = ported.filter { $0.kind == .line && ranks[$0.ours] != nil }
        // Rank by rank down the hierarchy, and a whole rank at a time: the classes
        // within one rank are the same road to a driver, so they take one width between
        // them rather than each capping the next.
        for rank in Set(roads.compactMap { ranks[$0.ours] }).sorted(by: >) {
            let here = roads.filter { ranks[$0.ours] == rank }
            let widths = here.compactMap {
                $0.width ?? theirs.section(.line, $0.theirs)?.lineWidth
            }
            guard let width = widths.min() else { continue }
            narrowest = min(narrowest, width)
            for port in here { capped[port.ours] = narrowest }
        }
        return ported.map { port in
            guard let width = capped[port.ours], port.kind == .line, width != port.width
            else { return port }
            return Ported(ours: port.ours, theirs: port.theirs, kind: port.kind,
                          meaning: port.meaning, witnesses: port.witnesses, width: width)
        }
    }

    /// What their style draws that no number of ours can carry: the list that says
    /// where kmap's own rules want widening.
    static func uncovered(codesByTag: [String: [String: Int]], rules: RuleSetIndex,
                          theirs: TypSource, ported: [Ported]) -> [Ported] {
        let taken = Set(ported.map { "\($0.kind.rawValue):\($0.theirs)" })
        var out: [String: Ported] = [:]
        // In the meanings' own order: a picture drawn as much for two of them would
        // otherwise be reported under whichever the dictionary handed over first.
        for tag in codesByTag.keys.sorted() {
            for (key, count) in codesByTag[tag] ?? [:] {
                guard let (kind, code) = read(key),
                      !taken.contains("\(kind.rawValue):\(code)"),
                      draws(theirs.section(kind, code)) else { continue }
                let held = out["\(kind.rawValue):\(code)"]
                if held == nil || count > held!.witnesses {
                    out["\(kind.rawValue):\(code)"] = Ported(
                        ours: 0, theirs: code, kind: kind, meaning: tag,
                        witnesses: count, width: nil)
                }
            }
        }
        return out.values.sorted {
            ($0.witnesses, $1.kind.rawValue, $1.theirs)
                > ($1.witnesses, $0.kind.rawValue, $0.theirs)
        }
    }

    /// Whether a section draws anything: an all-transparent pattern is a number kept
    /// for routing and left to the device.
    private static func draws(_ section: TypSection?) -> Bool {
        guard let section else { return false }
        let blocks = [section.xpm, section.dayXpm].compactMap { $0 }
        guard !blocks.isEmpty else { return false }
        return blocks.contains { block in
            // Colours only: a fill, and it draws whatever the palette says.
            guard !block.isSolid else { return block.colours.contains { $0 != nil } }
            // A pattern draws only where a pixel names an opaque colour.
            let opaque = Set(block.palette.filter { $0.colour != nil }.map(\.key))
            guard !opaque.isEmpty else { return false }
            return block.rows.contains { row in
                stride(from: 0, to: row.count, by: max(1, block.charsPerPixel)).contains {
                    at in
                    let start = row.index(row.startIndex, offsetBy: at)
                    let end = row.index(start, offsetBy: max(1, block.charsPerPixel),
                                        limitedBy: row.endIndex) ?? row.endIndex
                    return opaque.contains(String(row[start..<end]))
                }
            }
        }
    }

    /// What mkgmap manufactures rather than reads, and the number of theirs each takes
    /// its picture from. Contours, sea and the background are mkgmap's own on both
    /// sides, so there the number is the shared name. Land is not: kmap draws it on
    /// 0x27, where a borrowed style may keep a construction site, so it takes the paper
    /// the map is printed on — their background.
    static let generatedTypes: [(kind: MapElementKind, ours: Int, theirs: Int)] = [
        (.line, 0x20, 0x20), (.line, 0x21, 0x21), (.line, 0x22, 0x22),
        (.polygon, seaCode, seaCode), (.polygon, 0x4a, 0x4a),
        (.polygon, backgroundCode, backgroundCode),
        (.polygon, 0x27, backgroundCode),
    ]

    /// The sea and the background, the two grounds with a level of their own.
    static let seaCode = 0x32
    static let backgroundCode = 0x4b

    /// A rule with no band, in the ladder's own units: further in than any zoom.
    private static let everyZoom = 100

    /// The ground where their style paints none: kmap's own paper and sea, so the land
    /// is drawn at all. A polygon missing from the draw order is not drawn, and on a
    /// fenix an undrawn land goes black. The night pair is the one topoactive settled
    /// on a fenix: a grey that is unmistakably not water.
    static let paper = "#F4F4F0"
    static let paperAtNight = "#40403D"
    static let seaBlue = "#50A8F8"
    static let seaBlueAtNight = "#004C90"

    /// Whether their style is drawn for night too: most of its painted lines and
    /// polygons carry night colours. The ground supplied for it then carries them as
    /// well, and a day-only style gets a day-only ground, or the two would clash.
    static func paintsNight(_ typ: TypSource) -> Bool {
        let painted = typ.sections.filter { $0.kind != .point && $0.xpm != nil }
        guard !painted.isEmpty else { return false }
        return painted.filter { !$0.colourSlots.night.isEmpty }.count * 2 > painted.count
    }

    /// Below this brightness a fill is dark: mid-grey.
    static let darkBelow = 0.5

    /// Whether their day is dark: a TYP has no night-only mode, so a style made for
    /// the dark carries its dark colours in the day slot, and a paper ground under it
    /// would show as light holes. Most of the polygon fills darker than mid-grey.
    static func drawsDark(_ typ: TypSource) -> Bool {
        let fills = typ.sections.filter { $0.kind == .polygon }
            .compactMap { $0.xpm?.dominantColour ?? $0.xpm?.colours.first ?? nil }
        guard !fills.isEmpty else { return false }
        return fills.filter { brightness(of: $0) < darkBelow }.count * 2 > fills.count
    }

    /// Perceived brightness of `#RRGGBB`, 0 black to 1 white; 1 for anything unreadable.
    static func brightness(of colour: String) -> Double {
        let hex = colour.hasPrefix("#") ? String(colour.dropFirst()) : colour
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return 1 }
        let r = Double((value >> 16) & 0xff), g = Double((value >> 8) & 0xff)
        let b = Double(value & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    /// The line a ported palette carries to say it was written for kmap's numbers, and
    /// that what it does not paint is meant to stay undrawn.
    static let forOurNumbers = "kmap:for-kmap-numbers"

    /// Below this a picture is a coincidence, not a look their style keeps.
    private static let fewestToPort = 3

    /// What a rung must hold against the meaning's best-attested picture to count as one
    /// of its zooms rather than as a stray identification.
    private static let rungShare = 0.1

    /// How much of everything one of their numbers drew has to be this meaning for the
    /// picture to be the meaning's own rather than the ground it happened to lie on.
    /// A nature reserve is drawn over forest, so their forest was seen inside a few
    /// dozen reserve outlines — a fraction of a percent of the forest they drew.
    private static let strayShare = 0.02

    /// How often a picture below that share must still have been seen to be believed:
    /// a garden really is drawn as a park, five fords under a marker are not.
    private static let fewestIfStray = 50

    /// Where a rule sits on its ladder: `resolution 22-23` is a rung reaching 23, a
    /// bare `resolution 22` the rule itself, drawn at every zoom from there in.
    private static func rung(of tail: String) -> (banded: Bool, finest: Int) {
        guard let found = tail.range(of: "resolution [0-9]+(-[0-9]+)?",
                                     options: .regularExpression)
        else { return (false, GarminGrid.fullResolution) }
        let numbers = tail[found].split(separator: " ")[1].split(separator: "-")
        guard numbers.count == 2, let high = Int(numbers[1])
        else { return (false, GarminGrid.fullResolution) }
        return (true, high)
    }

    /// The evidence's key for a code of theirs, the form `theirZooms` is keyed by.
    private static func key(_ kind: MapElementKind, _ code: Int) -> String {
        switch kind {
        case .line: return "L" + String(code, radix: 16)
        case .polygon: return "A" + String(code, radix: 16)
        case .point: return "P" + String(code, radix: 16)
        }
    }

    /// `L11f14` and the like, as the evidence keys codes.
    private static func read(_ key: String) -> (MapElementKind, Int)? {
        guard let first = key.first, let code = Int(key.dropFirst(), radix: 16)
        else { return nil }
        switch first {
        case "L": return (.line, code)
        case "A": return (.polygon, code)
        case "P": return (.point, code)
        default: return nil
        }
    }

    /// The TYP source that carries their drawings on our numbers: each section is
    /// their block verbatim, with the type line rewritten to ours.
    static func typ(from theirs: TypSource, ported: [Ported],
                    familyID: Int?, productID: Int?, codePage: Int?,
                    unstyled: [MapElementKind: Set<Int>] = [:]) -> String {
        var out: [String] = []
        // First, or the compiler reads the file in the platform's charset and gives up
        // on the first Cyrillic label.
        out.append("; -*- coding: UTF-8 -*-")
        out.append("; ported by kmap: the pictures of a borrowed style, on kmap's numbers")
        // Read by the build, ignored by the compiler: this file is written against our
        // numbers, so a number it leaves unpainted is meant to draw nothing.
        out.append("; " + Self.forOurNumbers)
        out.append("[_id]")
        if let familyID { out.append("FID=\(familyID)") }
        if let productID { out.append("ProductCode=\(productID)") }
        if let codePage { out.append("CodePage=\(codePage)") }
        out.append("[end]")
        out.append("")
        // What their map leaves to the receiver stays a rule of ours, unpainted on
        // purpose: the receiver draws it, as it does on theirs.
        for kind in MapElementKind.allCases {
            guard let codes = unstyled[kind], !codes.isEmpty else { continue }
            let listed = codes.sorted().map { String(format: "0x%02x", $0) }.joined(separator: " ")
            out.append("; kmap:unstyled \(kind.rawValue)s \(listed) - their map leaves these"
                       + " to the receiver, which draws them itself")
        }
        if !unstyled.isEmpty { out.append("") }

        var drawOrder: [(code: Int, level: Int)] = []
        let theirOrder = Dictionary(theirs.drawOrder.map { ($0.code, $0.level) },
                                   uniquingKeysWith: { a, _ in a })

        // The ground the map stands on. No OSM way is its source, so no evidence pairs
        // it; both sides get it from mkgmap, and the number is the shared name.
        for (kind, ours, theirsCode) in Self.generatedTypes {
            if let section = theirs.section(kind, theirsCode) {
                out.append("; the build's own \(kind.rawValue) 0x\(String(ours, radix: 16))"
                           + " — drawn as their 0x\(String(theirsCode, radix: 16))")
                out.append(contentsOf: renumbered(theirs.lines[section.lines], to: ours,
                                                  kind: kind))
            } else if kind == .polygon {
                // Their style leaves the ground to the device; ours must not.
                let sea = ours == Self.seaCode
                let night = Self.paintsNight(theirs)
                let dark = Self.drawsDark(theirs)
                let byDay = sea ? (dark ? Self.seaBlueAtNight : Self.seaBlue)
                    : (dark ? Self.paperAtNight : Self.paper)
                out.append("; the build's own polygon 0x\(String(ours, radix: 16))"
                           + " - their style paints none, so kmap's own ground")
                out.append("[_polygon]")
                out.append(String(format: "Type=0x%02x", ours))
                out.append(night ? "Xpm=\"0 0 2 0\"" : "Xpm=\"0 0 1 0\"")
                out.append("\"1 c \(byDay)\"")
                if night { out.append("\"2 c \(sea ? Self.seaBlueAtNight : Self.paperAtNight)\"") }
                out.append("[end]")
            } else {
                continue
            }
            out.append("")
            // The order kmap's own palettes keep. Sharing a level is no order at all:
            // mkgmap writes shapes by descending area, and on a fenix the land loses to
            // the background and the map goes black.
            if kind == .polygon {
                // 0 the background alone, 1 the land and the overview's land, 2 the sea.
                let level = ours == Self.backgroundCode ? 0 : (ours == Self.seaCode ? 2 : 1)
                drawOrder.append((ours, level))
            }
        }
        for port in ported {
            guard let section = theirs.section(port.kind, port.theirs) else { continue }
            out.append("; \(port.meaning) — kmap 0x\(String(port.ours, radix: 16))"
                       + " drawn as their 0x\(String(port.theirs, radix: 16))"
                       + " (\(port.witnesses) seen)")
            out.append(contentsOf: narrowed(renumbered(theirs.lines[section.lines],
                                                       to: port.ours, kind: port.kind),
                                            to: port.width))
            out.append("")
            // Above the ground: their own level, moved up by the two the background and
            // the land keep to themselves.
            if port.kind == .polygon, let level = theirOrder[port.theirs] {
                drawOrder.append((port.ours, level + 3))
            }
        }
        if !drawOrder.isEmpty {
            out.append("[_drawOrder]")
            for entry in drawOrder.sorted(by: { ($0.level, $0.code) < ($1.level, $1.code) }) {
                out.append(String(format: "Type=0x%02x,%d", entry.code, entry.level))
            }
            out.append("[end]")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The block drawn at a width of its own: only `LineWidth=` changes, and only
    /// downward — a bitmap's thickness is the picture itself and is left alone.
    private static func narrowed(_ block: [String], to width: Int?) -> [String] {
        guard let width else { return block }
        return block.map { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("LineWidth="),
                  let had = Int(text.dropFirst("LineWidth=".count)), width < had
            else { return line }
            return "LineWidth=\(width)"
        }
    }

    /// Their block with the type lines rewritten to our number; a point's low byte is
    /// its subtype, written on a line of its own.
    private static func renumbered(_ block: ArraySlice<String>, to code: Int,
                                   kind: MapElementKind) -> [String] {
        let type = kind == .point ? code >> 8 : code
        let subtype = kind == .point ? code & 0xff : 0
        var out: [String] = []
        var wroteSubtype = false
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Type=") {
                out.append(String(format: "Type=0x%02x", type))
            } else if trimmed.hasPrefix("SubType=") {
                out.append(String(format: "SubType=0x%02x", subtype))
                wroteSubtype = true
            } else {
                out.append(line)
            }
        }
        // A point whose block never said SubType still needs one when ours has a low
        // byte.
        if kind == .point, !wroteSubtype, subtype != 0,
           let at = out.firstIndex(where: { $0.hasPrefix("Type=") }) {
            out.insert(String(format: "SubType=0x%02x", subtype), at: at + 1)
        }
        return out
    }
}
