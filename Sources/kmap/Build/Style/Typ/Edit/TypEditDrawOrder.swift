import Foundation

/// The `[_drawOrder]` table of a TYP source: the level each polygon is painted on. A
/// polygon absent from the table is not drawn at all.
extension TypEdit {
    /// What kmap writes above an entry it added, on a line of its own.
    static let addedNote = "; added by kmap"
    private static let tableHeader = "[_draworder]"
    private static let tableEnd = "[end]"

    private static func isAddedNote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased() == addedNote
    }

    /// Puts a polygon into the draw order, at the level asked for or on top of everything.
    static func insertIntoDrawOrder(_ lines: inout [String], code: Int, level: Int?) {
        guard let table = drawOrderTable(in: lines) else { return }
        // The highest level in the table, so a new polygon lands above ground cover
        // rather than hidden beneath it.
        let highest = lines[table].compactMap { drawOrderEntry(of: $0)?.level }.max() ?? 1
        placeInDrawOrder(
            &lines,
            table: table,
            entry: "Type=\(TypeMeaning.hex(code))",
            level: level ?? highest,
            note: addedNote
        )
    }

    /// Moves a polygon to another level of the draw order, or adds a missing one.
    ///
    /// The entry is written among the others of its new level, so a table kept in level
    /// order stays that way. The code keeps its spelling; kmap's own note above the
    /// entry moves with it.
    /// - Throws: `EditError.noDrawOrder` without a table, `.notALevel` below 1.
    static func setDrawOrderLevel(
        in source: TypSource,
        code: Int,
        to level: Int
    ) throws -> String {
        guard level >= 1 else { throw EditError.notALevel(level) }
        var lines = source.lines
        guard let table = drawOrderTable(in: lines) else { throw EditError.noDrawOrder }

        var spelling = "Type=\(TypeMeaning.hex(code))"
        var note: String?
        if let number = table.first(where: { drawOrderEntry(of: lines[$0])?.code == code }) {
            spelling = drawOrderEntry(of: lines[number])?.spelling ?? spelling
            // Only kmap's own note moves: a divider above the entry belongs to the group.
            if number > table.lowerBound,
                isAddedNote(lines[number - 1])
            {
                note = addedNote
            }
        }
        removeFromDrawOrder(&lines, code: code)
        guard let again = drawOrderTable(in: lines) else { throw EditError.noDrawOrder }
        placeInDrawOrder(&lines, table: again, entry: spelling, level: level, note: note)
        return lines.joined(separator: "\n")
    }

    /// Rearranges the table so that the `tints` are drawn over every one of `covers` and
    /// the `woods` over the tints: the 2 are taken out and put back, the tints on 1 new
    /// level and the woods above them, right over the highest cover. The woods keep the
    /// order they had among themselves, and everything that was above that cover stays
    /// above the woods.
    ///
    /// - Returns: false where nothing was changed: no table, no tint or no wood in it, or
    ///   the 3 already in that order.
    @discardableResult
    static func layWoodsOverTints(
        _ lines: inout [String],
        tints: [Int],
        woods: [Int],
        covers: Set<Int>
    ) -> Bool {
        guard let table = drawOrderTable(in: lines) else { return false }
        let entries = table.compactMap { drawOrderEntry(of: lines[$0]) }
        let heldTints = entries.filter { tints.contains($0.code) }
        let heldWoods = entries.filter { woods.contains($0.code) }
        guard let lowestTint = heldTints.map(\.level).min(), let highestTint = heldTints.map(\.level).max(),
            let lowestWood = heldWoods.map(\.level).min()
        else { return false }
        let highestCover = entries.filter { covers.contains($0.code) }.map(\.level).max()
        if highestTint < lowestWood, (highestCover ?? Int.min) < lowestTint { return false }

        // Where the 2 go back in: over the highest cover, or where the lower of them was.
        let under = highestCover ?? (min(lowestTint, lowestWood) - 1)
        let woodLevels = Array(Set(heldWoods.map(\.level))).sorted()
        let room = 1 + woodLevels.count
        for code in (heldTints + heldWoods).map(\.code) { removeFromDrawOrder(&lines, code: code) }
        guard let rest = drawOrderTable(in: lines) else { return false }
        for number in rest {
            guard let entry = drawOrderEntry(of: lines[number]), entry.level > under else { continue }
            lines[number] = indentation(of: lines[number]) + "\(entry.spelling),\(entry.level + room)"
        }
        for tint in heldTints {
            guard let now = drawOrderTable(in: lines) else { return false }
            placeInDrawOrder(&lines, table: now, entry: tint.spelling, level: under + 1, note: nil)
        }
        for wood in heldWoods {
            guard let now = drawOrderTable(in: lines), let step = woodLevels.firstIndex(of: wood.level)
            else { return false }
            placeInDrawOrder(&lines, table: now, entry: wood.spelling, level: under + 2 + step, note: nil)
        }
        return true
    }

    /// Puts new polygons on levels of their own right over the highest of `woods`: each
    /// with the step it is to stand on, 0 the lowest, and everything that was over the
    /// woods moving up to make room.
    ///
    /// - Returns: false where nothing was changed: no table, or no wood in it.
    @discardableResult
    static func layOverWoods(_ lines: inout [String], lifted: [(code: Int, step: Int)], woods: [Int]) -> Bool {
        guard let table = drawOrderTable(in: lines), !lifted.isEmpty else { return false }
        let entries = table.compactMap { number in
            drawOrderEntry(of: lines[number]).map { (number: number, entry: $0) }
        }
        guard let top = entries.filter({ woods.contains($0.entry.code) }).map(\.entry.level).max()
        else { return false }
        let room = (lifted.map(\.step).max() ?? 0) + 1
        for (number, entry) in entries where entry.level > top {
            lines[number] = indentation(of: lines[number]) + "\(entry.spelling),\(entry.level + room)"
        }
        for one in lifted {
            removeFromDrawOrder(&lines, code: one.code)
            guard let now = drawOrderTable(in: lines) else { return false }
            placeInDrawOrder(
                &lines,
                table: now,
                entry: "Type=\(TypeMeaning.hex(one.code))",
                level: top + 1 + one.step,
                note: addedNote
            )
        }
        return true
    }

    /// Writes an entry after the last one at or below its level, or at the top where
    /// none is. The note goes on its own line: the TYP compiler reads an entry to the
    /// end of the line, and a comment behind the level breaks the whole file.
    private static func placeInDrawOrder(
        _ lines: inout [String],
        table: Range<Int>,
        entry: String,
        level: Int,
        note: String?
    ) {
        var at = table.lowerBound
        for number in table {
            guard let entry = drawOrderEntry(of: lines[number]), entry.level <= level
            else { continue }
            at = number + 1
        }
        let indent = table.isEmpty ? "" : indentation(of: lines[table.lowerBound])
        var written = [indent + "\(entry),\(level)"]
        if let note { written.insert(indent + note, at: 0) }
        lines.insert(contentsOf: written, at: at)
    }

    /// The lines between `[_drawOrder]` and its `[end]`, exclusive; nil without a table.
    private static func drawOrderTable(in lines: [String]) -> Range<Int>? {
        func marks(_ line: String, _ marker: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).lowercased() == marker
        }
        guard let open = lines.firstIndex(where: { marks($0, tableHeader) }),
            let close = lines[open...].firstIndex(where: { marks($0, tableEnd) })
        else { return nil }
        return open + 1..<close
    }

    /// Removes every draw-order entry for a polygon, with kmap's own note above it.
    static func removeFromDrawOrder(_ lines: inout [String], code: Int) {
        guard let table = drawOrderTable(in: lines) else { return }
        var going: Set<Int> = []
        for number in table where drawOrderEntry(of: lines[number])?.code == code {
            going.insert(number)
            if number > table.lowerBound,
                isAddedNote(lines[number - 1])
            {
                going.insert(number - 1)
            }
        }
        for number in going.sorted(by: >) { lines.remove(at: number) }
    }

    /// An entry like `Type=0x04b,5`: the type, its level (0 where none is given) and the
    /// type as spelt in the file. Nil for any other line. A comment behind the level,
    /// which an older kmap wrote, does not hide the entry.
    private static func drawOrderEntry(
        of line: String
    ) -> (code: Int, level: Int, spelling: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("type="), let eq = trimmed.firstIndex(of: "=")
        else { return nil }
        let value = trimmed[trimmed.index(after: eq)...].prefix { $0 != ";" }
        let parts = value.split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return nil }
        let digits = first.lowercased().hasPrefix("0x") ? String(first.dropFirst(2)) : first
        guard let code = Int(digits, radix: 16) else { return nil }
        let level = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (code, level, "Type=\(first)")
    }
}
