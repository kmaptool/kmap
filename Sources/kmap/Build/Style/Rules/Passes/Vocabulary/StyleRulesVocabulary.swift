import Foundation

/// Meanings kmap drew as one and a borrowed style draws apart.
///
/// Two meanings on one number share a look: allotments and an orchard both sat on 0x4e.
/// Each gets a number of kmap's own, and a palette that paints no picture for the new
/// number keeps the old one (below), so no map changes until a palette says otherwise.
extension StyleCatalog {
    /// A meaning moved onto a number of its own, and the number it drew on before: an
    /// unpainted new number sends the rule back to the old one, so a style written
    /// before the widening draws exactly what it drew. `was: nil` is a layer that never
    /// existed - a building's outline - and is removed instead.
    static let widenedNumbers: [(kind: MapElementKind, now: Int, was: Int?)] = [
        (.polygon, 0x5a, 0x4e),  // allotments, drawn as an orchard before
        (.polygon, 0x0d, 0x0c),  // a quarry, drawn as industrial ground before
        (.polygon, 0x1b, 0x4e),  // a vineyard, drawn as an orchard before
        (.polygon, 0x1e, 0x4f),  // heath, drawn as scrub before
        (.polygon, 0x1f, nil),  // a mountain plateau: new, and only where drawn
        (.polygon, 0x5b, nil),  // the floor under scrub: new, and only where drawn
        (.polygon, 0x28, nil),  // a salt pond: new
        (.polygon, 0x29, nil),  // greenhouses: new
        (.line, 0x0e, 0x16),  // a path, drawn as a footway before
        (.line, 0x0f, 0x16),  // steps, retagged into a footway before
        (.line, 0x10, 0x06),  // a living street, drawn as a minor road before
        (.line, 0x31, 0x17),  // a row of trees, drawn as a fence before
        (.line, 0x32, nil),  // a city wall: new, and only where drawn
        (.line, 0x33, 0x1f),  // a canal, drawn as a river before
        (.line, 0x34, 0x18),  // a drain, drawn as a stream before
        (.line, 0x35, 0x18),  // a ditch, drawn as a stream before
        (.line, 0x2f, nil),  // a building's outline: new, and only where drawn
        (.line, 0x36, 0x14),  // a tram, drawn as a railway before
        // A grade, drawn as any via ferrata before. Where 0x37 is unpainted too the build
        // draws the via ferrata as a path, after the road twins (`drawFerrataAsPath`).
        (.line, 0x39, 0x37),
        (.line, 0x3a, 0x37),
        (.line, 0x3b, 0x37),
        (.line, 0x3c, 0x37),
        (.line, 0x3d, 0x37),
        (.line, 0x38, 0x25),  // a cable car, drawn as a lift before
        (.point, 0x0d00, 0x0b00),  // a hamlet, drawn as a locality before
        (.point, 0x6608, 0x6411),  // a tower, drawn as a mast before
        (.point, 0x6609, 0x6411),  // a mast, drawn as a pylon before
        (.point, 0x660a, nil)  // the ends of a via ferrata: new, and only where drawn
    ]

    /// Puts a widened rule back on the number it drew on before. Runs before the
    /// palette filter, which would otherwise silence it and lose the meaning.
    @discardableResult
    static func keepTheOldNumberWherePaletteIsSilent(
        in directory: URL,
        palette: TypSource,
        log: Log
    ) throws -> Int {
        var moved = 0
        for kind in MapElementKind.allCases {
            let wanted = widenedNumbers.filter { $0.kind == kind }
            guard !wanted.isEmpty else { continue }
            let painted = palette.codes(kind).union(palette.deliberatelyUnstyled[kind] ?? [])
            guard !painted.isEmpty else { continue }
            let url = directory.appendingPathComponent(kind.ruleFile)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var touched = false
            for entry in wanted where !painted.contains(entry.now) {
                let from = "[" + TypeMeaning.hex(entry.now) + " "
                guard text.contains(from) else { continue }
                // A number a person aimed a rule at by hand keeps it.
                func mine(_ line: String) -> Bool {
                    line.contains(from) && !line.contains(RuleReassignment.mark)
                }
                guard let was = entry.was else {
                    // A `continue` layer, so the rule below still lays the fill down.
                    // Left in, it would reach the receiver's own drawing.
                    text = text.components(separatedBy: "\n")
                        .filter { !mine($0) }.joined(separator: "\n")
                    touched = true
                    moved += 1
                    continue
                }
                let to = "[" + TypeMeaning.hex(was) + " "
                text = text.components(separatedBy: "\n")
                    .map { mine($0) ? $0.replacingOccurrences(of: from, with: to) : $0 }
                    .joined(separator: "\n")
                touched = true
                moved += 1
            }
            if touched { try FileTools.write(text, to: url) }
        }
        if moved > 0 {
            log.append(
                "\(moved) rule(s) drawn on the number they had before"
                    + " — this palette paints no picture for the newer one"
            )
        }
        return moved
    }

    func widenDrawnVocabulary(in directory: URL, log: Log) throws {
        var done: [String] = []
        for (name, file, old, new) in Self.renumberedStockRules
        where try edit(file: file, in: directory, old: old, new: new) {
            done.append(name)
        }
        for (name, file, marker, text) in Self.addedLayers
        where try spliceRules(text, marked: marker, intoFile: file, in: directory) {
            done.append(name)
        }
        if !done.isEmpty {
            log.append("drawn vocabulary widened: \(done.joined(separator: ", "))")
        }
    }

    /// One exact-text edit of a rule file. Returns false where the text has changed in
    /// this mkgmap and the anchor no longer matches - the caller says nothing then, and
    /// the stock rule stands.
    private func edit(
        file: String,
        in directory: URL,
        old: String,
        new: String
    ) throws -> Bool {
        let url = directory.appendingPathComponent(file)
        guard var text = try? String(contentsOf: url, encoding: .utf8),
            text.contains(old)
        else { return false }
        text = text.replacingOccurrences(of: old, with: new)
        try FileTools.write(text, to: url)
        return true
    }
}
