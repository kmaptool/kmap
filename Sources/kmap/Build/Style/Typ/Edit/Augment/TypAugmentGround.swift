import Foundation

/// The ground layering a build asks of a borrowed TYP: tints under woods, and open ground
/// lifted over them.
extension TypAugment {
    /// The ground tints a wood is drawn over: a residential area, a village, a suburb
    /// and the grounds of a hotel or a camp. OSM draws a wood across a settlement
    /// without cutting either out, and the wood is the ground truth of the 2: the tint
    /// goes under it, and the houses and roads are drawn over the 2 of them.
    static let groundTints = [0x10, 0x03, 0x02, 0x21]

    /// What is drawn over a ground tint, on kmap's numbers: a wood, which is its floor
    /// and the 3 kinds drawn on it, and an orchard.
    static let woods = [0x59, 0x50, 0x57, 0x58, 0x4e]

    /// Open ground and what is farmed in the open: the covers a ground tint stays over.
    /// A meadow, a field or a plateau drawn round a village is the land the village
    /// stands in. Scrub and its floor, vineyards, allotments, fields, farms, grass,
    /// heath, plateaux, tundra, sand and ice.
    static let openCovers: Set<Int> = [
        0x4f, 0x5b, 0x1b, 0x5a, 0x1c, 0x26, 0x55, 0x1e, 0x1f, 0x52, 0x53, 0x4d
    ]

    /// A wood proper, without the orchard: what open ground may lie on and still show.
    static let forest = [0x59, 0x50, 0x57, 0x58]

    /// Open ground that OSM draws across a wood with no hole cut for it: a glade, a
    /// patch of scrub or heath, a field. Lying on a wood larger than itself it takes a
    /// second number, a copy of its picture on a level over the woods; a patched mkgmap
    /// decides which shape gets it. The step is the level the copy stands on over the
    /// woods: the scrub's floor under everything else.
    static let liftedOverWoods: [(code: Int, step: Int)] = [
        (0x5b, 0), (0x4f, 1), (0x55, 1), (0x1e, 1), (0x1c, 1)
    ]

    /// Where a copy's number is looked for.
    static let copyNumbers = 0x5c...0x7f

    /// Copies of the open ground's pictures on free numbers, laid over the woods in `text`;
    /// none where the style holds no woods to lay them over.
    static func liftOpenGround(
        in source: TypSource,
        text: inout String,
        rules: URL?,
        moved: [MapElementKind: [Int: Int]]
    ) -> (copies: [(code: Int, text: String)], shapeLift: String?) {
        var copies: [(code: Int, text: String)] = []
        var shapeLift: String?
        var taken = numbersInUse(.polygon, by: rules).union(moved[.polygon].map { Set($0.values) } ?? [])
        var pairs: [(from: Int, to: Int, step: Int)] = []
        for open in liftedOverWoods {
            // The nearest free number over the ones kmap already draws, not one from
            // the top of the range: no receiver has been seen to draw those.
            guard let section = source.section(.polygon, open.code),
                let free = copyNumbers.first(where: {
                    source.section(.polygon, $0) == nil && !taken.contains($0)
                })
            else { continue }
            taken.insert(free)
            pairs.append((open.code, free, open.step))
            let copy = source.lines[section.lines].map { line in
                typeCode(of: line) == nil ? line : TypEdit.indentation(of: line) + "Type=" + TypeMeaning.hex(free)
            }
            copies.append((free, copy.joined(separator: "\n")))
        }
        let held = forest.filter { code in source.drawOrder.contains { $0.code == code } }
        var liftLines = text.components(separatedBy: "\n")
        if !pairs.isEmpty, !held.isEmpty,
            TypEdit.layOverWoods(&liftLines, lifted: pairs.map { ($0.to, $0.step) }, woods: woods)
        {
            text = liftLines.joined(separator: "\n")
            shapeLift =
                "--x-shape-lift="
                + pairs.map { TypeMeaning.hex($0.from) + ">" + TypeMeaning.hex($0.to) }.joined(separator: ",")
                + ":" + held.map(TypeMeaning.hex).joined(separator: ",")
        } else {
            copies = []
        }
        return (copies, shapeLift)
    }
}
