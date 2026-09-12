import Foundation

/// What a build is called: on the receiver, in the .img header and on disk.
extension BuildRecipe {
    /// The map's series name. Receivers display it only when it is short, so the device
    /// title stands in; the region names stay in `mapName` and the Map Info block.
    var seriesName: String { deviceTitle }

    /// What a receiver lists the map as: the title again.
    var familyName: String { headerDescription }

    /// Garmin's own limit on the description field in an `.img` header.
    static let headerDescriptionLimit = 50

    /// What goes into the `.img` header: the device title, shown as the bold first line of
    /// the map's card. Fitted to the limit, since mkgmap refuses a longer one only after
    /// every tile is compiled.
    var headerDescription: String {
        Self.fitted(deviceTitle, to: Self.headerDescriptionLimit)
    }

    /// The bold line on the receiver: the tool, the month, and the region ids, which are
    /// ASCII whatever the code page.
    var deviceTitle: String {
        let head = "kmap \(dateStamp.prefix(7)), "
        return Self.fittedIDs(regions.map(\.id), limit: Self.headerDescriptionLimit) { named, rest in
            head + named.joined(separator: rest > 0 ? ", " : " and ")
                + (rest > 0 ? " and \(rest) more" : "")
        }
    }

    /// Up to two of `ids` within `limit`, the rest counted: `spell` renders the named ids
    /// and the count. One id where two do not fit; that id cut at a hyphen as the last
    /// resort. The count always survives.
    static func fittedIDs(_ ids: [String], limit: Int,
                          spell: ([String], Int) -> String) -> String {
        for named in [2, 1] where ids.count >= named {
            let text = spell(Array(ids.prefix(named)), ids.count - named)
            if text.count <= limit { return text }
        }
        guard let first = ids.first else { return spell([], 0) }
        let overhead = spell([""], ids.count - 1).count
        let cut = fitted(first, to: max(1, limit - overhead), breakingOn: "-")
        return spell([cut], ids.count - 1)
    }

    static func fitted(_ text: String, to limit: Int,
                       breakingOn separator: Character = " ") -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        // Only take the word boundary if it leaves most of the room used; a short first
        // word would otherwise cut the text back to almost nothing.
        if let word = cut.lastIndex(of: separator),
           cut.distance(from: cut.startIndex, to: word) > limit / 2 {
            return String(cut[cut.startIndex..<word])
        }
        return cut
    }

    /// What the map is called: one region's name, or the set spelled out. Not translated,
    /// since the text is written into the map itself.
    var mapName: String { Self.spelledOut(regions.map(\.name), upTo: 3) }

    /// Up to `upTo` items spelled out; past that, the first `upTo` and a count.
    static func spelledOut(_ items: [String], upTo: Int) -> String {
        if items.count > upTo {
            return items.prefix(upTo).joined(separator: ", ") + " and \(items.count - upTo) more"
        }
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and \(items[items.count - 1])"
        }
    }

    /// A file-safe id for the map: the region's id, or the first two ids and a count.
    var slug: String {
        guard !extraRegions.isEmpty else { return FileTools.slugify(region.id) }
        let head = regions.prefix(2).map { FileTools.slugify($0.id) }.joined(separator: "+")
        return regions.count > 2 ? "\(head)+\(regions.count - 2)" : head
    }

    /// Names for the produced files. The naming belongs to `TilePacker`, which decides the
    /// grouping.
    func partNames(count: Int, axis: SplitAxis) -> [String] {
        TilePacker(mode: splitMode, axis: axis, slug: slug).partNames(count: count)
    }

    /// The day this build started, as it appears in every name it writes.
    var dateStamp: String { Fmt.day(startedOn) }

    /// How much of the slug a file name carries.
    static let fileNamePartLimit = 48

    /// One finished file: the regions, its part of `total` if several, the date last so
    /// builds sort apart on a card, and the copy number from 2 up.
    func fileName(ordinal: Int = 1, of total: Int = 1, copy: Int = 1) -> String {
        let part = total > 1 ? "p\(ordinal)-" : ""
        let bump = copy > 1 ? "-\(copy)" : ""
        return "kmap-\(regionsFileToken)-\(part)\(dateStamp)\(bump).img"
    }

    /// The ids as a file name says them: "a+b", "a+b+N-more", fitted like the title.
    private var regionsFileToken: String {
        Self.fittedIDs(regions.map { FileTools.slugify($0.id) }, limit: Self.fileNamePartLimit) {
            named, rest in
            named.joined(separator: "+") + (rest > 0 ? "+\(rest)-more" : "")
        }
    }

    /// A bound only against a `taken` that never says no; a folder runs out of names
    /// to have taken long before this.
    private static let mostCopies = 10_000

    /// The lowest copy number whose file names are all still free.
    ///
    /// Asked once per build, for every part at once: the parts of one build must share a
    /// number, or part one could come out "-2" while part two did not and the set would
    /// stop reading as a set.
    ///
    /// `taken` answers for the *other* builds in the output folder - the caller leaves
    /// its own destination out, so rebuilding the same map on the same day still replaces
    /// its own files rather than growing a number each time.
    func freeCopy(of total: Int, taken: (String) -> Bool) -> Int {
        var copy = 1
        while copy < Self.mostCopies {
            let anyTaken = (1...max(1, total)).contains { ordinal in
                taken(fileName(ordinal: ordinal, of: total, copy: copy))
            }
            if !anyTaken { return copy }
            copy += 1
        }
        return copy
    }

    /// The lines shown under Map Info; mkgmap shows the first in BaseCamp only.
    /// Plain ASCII, no punctuation past a comma: Garmin's six-bit label alphabet drops a
    /// line from the first character it cannot hold. OSM attribution is licence-required.
    var copyrightLines: [String] {
        // kmap's own date rather than mkgmap's $LONGDATE$, which is written in the Java
        // locale and can contain characters the label alphabet does not hold.
        var lines = ["kmap \(Version.number), mkgmap $MKGMAP_VERSION$, built \(dateStamp)",
                     "(c) OpenStreetMap contributors, ODbL",
                     "Built by kmap \(Version.number), \(dateStamp)"]
        if contours || demLayer {
            lines.append("Elevation: \(demSources.replacingOccurrences(of: ",", with: " "))"
                         + (contours ? ", contours \(contourInterval) m" : ""))
        }
        // A borrowed look whose licence asks to be credited is credited here, where the
        // receiver shows it: the map is the product the licence speaks of.
        if let shipped = StyleCatalog.shippedPalette(id: style.id), !shipped.credit.isEmpty {
            lines.append(shipped.credit)
        }
        return lines
    }

    /// The dated folder each build writes into, so repeated builds of the same region do
    /// not overwrite each other.
    var outputFolderName: String {
        var parts: [String] = [dateStamp, slug]
        parts.append(FileTools.slugify(style.id.replacingOccurrences(of: ":", with: "-")))
        if contours { parts.append("\(contourInterval)m") }
        if demLayer { parts.append("dem") }
        return parts.joined(separator: "_")
    }

    /// The folder this build writes its finished maps into.
    var destinationDirectory: URL {
        outputDirectory.appendingPathComponent(outputFolderName, isDirectory: true)
    }

    /// Private scratch directory for this build, removed when it finishes.
    var workDirectory: URL {
        workRoot.appendingPathComponent(slug, isDirectory: true)
    }
}
