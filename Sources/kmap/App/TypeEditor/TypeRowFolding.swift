import Foundation

/// The type rows with runs of anonymous codes folded into one line each: a code with no
/// rule, no TYP section and no convention says nothing, and a wall of them tells nobody
/// anything.
struct TypeRowFolding {
    /// A fold: the last code of the run and how many it stands for.
    typealias Span = (last: Int, count: Int)

    /// Runs shorter than this are listed as they are.
    static let leastRunToFold = 3

    let rows: [StyleTypeRow]
    /// Each fold's span, keyed by the code of the row standing for it.
    let spans: [Int: Span]

    static func anonymous(_ row: StyleTypeRow, kind: MapElementKind) -> Bool {
        !row.isStyled && !row.isEmitted && GarminStandard.meaning(kind, row.code, russian: false) == nil
    }

    /// An unfold opens the whole run: touching any of its codes keeps it open.
    static func fold(_ all: [StyleTypeRow], kind: MapElementKind, expanded: Set<Int>) -> TypeRowFolding {
        var out: [StyleTypeRow] = []
        var spans: [Int: Span] = [:]
        var i = 0
        while i < all.count {
            guard anonymous(all[i], kind: kind) else {
                out.append(all[i])
                i += 1
                continue
            }
            var j = i
            while j + 1 < all.count, anonymous(all[j + 1], kind: kind) { j += 1 }
            let opened = (i...j).contains { expanded.contains(all[$0].code) }
            if j - i + 1 >= leastRunToFold, !opened {
                out.append(all[i])
                spans[all[i].code] = (all[j].code, j - i + 1)
            } else {
                out.append(contentsOf: all[i...j])
            }
            i = j + 1
        }
        return TypeRowFolding(rows: out, spans: spans)
    }
}
