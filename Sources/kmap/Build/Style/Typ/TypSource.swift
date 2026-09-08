import Foundation

/// A parsed mkgmap TYP *source* file: the `.txt` form, not the compiled binary.
///
/// Read-only. Nothing in this type writes.
struct TypSource {
    /// The file split on newlines, verbatim. Reassembling with `\n` returns the original.
    let lines: [String]

    let familyID: Int?
    let productID: Int?
    let codePage: Int?

    let sections: [TypSection]

    /// `[_drawOrder]` entries as (type, level). A polygon absent from this table is never
    /// drawn.
    let drawOrder: [(code: Int, level: Int)]

    /// Types the file declares as deliberately left to the device, by kind, so a coverage
    /// report can skip them. Carried in a comment the TYP compiler ignores:
    ///
    ///     ; kmap:unstyled lines 0x01 0x02 0x03 — the road hierarchy, left to the device
    let deliberatelyUnstyled: [MapElementKind: Set<Int>]

    var text: String { lines.joined(separator: "\n") }

    // MARK: Lookup

    func sections(_ kind: MapElementKind) -> [TypSection] {
        sections.filter { $0.kind == kind }
    }

    func section(_ kind: MapElementKind, _ code: Int) -> TypSection? {
        sections.first { $0.kind == kind && $0.code == code }
    }

    func codes(_ kind: MapElementKind) -> Set<Int> {
        Set(sections.filter { $0.kind == kind }.map(\.code))
    }

    /// Polygon codes the draw order omits. Each is styled and never drawn.
    var polygonsMissingFromDrawOrder: [Int] {
        let ordered = Set(drawOrder.map(\.code))
        return codes(.polygon).subtracting(ordered).sorted()
    }
}
