import Foundation

extension StyleRecovery.SheetWriter {
    /// Rules the foreign style would repaint into a lie are silenced: barracks over
    /// every field. A rule is deleted only when every one of these holds:
    ///
    /// - their TYP does not paint the code, which leaves the receiver's own look, one
    ///   neither map has; or it does, and their map was seen using the code for other
    ///   meanings: the number is theirs and means something else;
    /// - their map was not seen drawing the rule itself, under whatever code;
    /// - no claim re-aimed the rule. A number carries no meaning of its own: ours for a ford
    ///   and theirs for an information board both being 0x6514 says nothing about fords, and
    ///   leaving the rule to that coincidence puts an `i` on every ford. Their style has no
    ///   picture for a ford, so none is drawn: the map ports what its author drew;
    /// - the rule carries no routing. Deleting a routable rule breaks every route through what
    ///   it drew, and it cannot be re-aimed, as receivers route only on the plain road types.
    ///   It keeps its code and wears their colours, the least of the harms on offer.
    func silencedRuleSheet() -> [String] {
        // A map with no TYP to read hands over no vocabulary at all, and silencing every
        // rule against an empty one would leave an empty map.
        guard !typDefined.isEmpty else { return [] }
        var sheet: [String] = []
        for kind in [ElementDumper.Kind.line, .area, .point] {
            let file = DefaultRuleBook.file(for: kind)
            for line in rules.allLines(forKind: file) {
                guard claimed[line.file + ":" + line.text] == nil,
                    !witnessedSlots.contains("\(kind.rawValue):\(line.file):\(line.text)"),
                    let type = Int(line.code, radix: 16)
                else { continue }
                guard !line.text.contains("road_class=") else { continue }
                guard
                    !StyleRecovery.generated.contains(
                        Evidence.key(kind, type).uppercased()
                    )
                else { continue }
                // A point code below 0x100 is a bare type; the TYP folds the subtype in.
                let painted = kind == .point && type < 0x100 ? type << 8 : type
                let verdict = claims.verdicts[StyleRecovery.codeKey(kind, type)]
                // Their TYP not painting the number is a fact about their style, not
                // about the ground compared: they have no picture for this at all, and
                // the receiver would fall back on its own - a look neither map has.
                // Where they do paint it, only their own witnesses can say whether the
                // picture belongs here; with none either way, their paint stands.
                if typDefined[kind]?.contains(painted) == true, verdict?.agrees != false {
                    continue
                }
                sheet.append("@@ \(line.file)")
                sheet.append(
                    String(
                        format: "# their map draws 0x%02x as %@ — silenced,"
                            + " so their look stays honest",
                        type,
                        verdict?.meaning ?? "nothing at all"
                    )
                )
                sheet.append("- \(line.text)")
                if let second = line.continuation { sheet.append("- \(second)") }
            }
        }
        return sheet
    }
}
