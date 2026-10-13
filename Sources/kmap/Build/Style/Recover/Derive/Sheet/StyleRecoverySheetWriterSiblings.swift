import Foundation

extension StyleRecovery.SheetWriter {
    /// Step five and a half: the rules this evidence never reached.
    ///
    /// The paint belongs to the code, not to the rule that happened to be witnessed
    /// with it. A roundabout is a trunk road written under `junction=roundabout`, and
    /// the ways carrying that tag were counted as trunk roads - so the trunk rule
    /// learned the ladder and the roundabout rule, drawn on the same blank number,
    /// learned nothing and came out invisible. Any rule closing on a code whose ladder
    /// is known gets that ladder, banded exactly as the witnessed rule's was.
    func siblingRuleSheet(already: Set<String>) -> [String] {
        var sheet: [String] = []
        for kind in [ElementDumper.Kind.line, .area, .point] {
            let file = DefaultRuleBook.file(for: kind)
            for line in rules.allLines(forKind: file) {
                // A rule written over two lines takes no strokes, here as in the
                // claimed pass: a stroke is one line, and the condition of a rule
                // written apart from its type would be left behind.
                guard !line.isSplit, !already.contains(line.text),
                    let ladder = ladders[line.file + ":" + line.code],
                    !ladder.isEmpty
                else { continue }
                // A rule already drawn with one of its own strokes needs nothing.
                guard !ladder.contains(where: { line.emits($0.type) }) else { continue }
                let paint = ladder.filter { !StyleRecovery.routable($0.type) }
                guard !paint.isEmpty else { continue }
                sheet.append("@@ \(line.file)")
                sheet.append("- \(line.text)")
                if let second = line.continuation { sheet.append("- \(second)") }
                let strokes = paint.map {
                    Self.banded(line, to: $0.type, resolutions: $0.resolutions)
                }
                sheet.append(contentsOf: Self.keeping(line, under: strokes))
            }
        }
        return sheet
    }
}
