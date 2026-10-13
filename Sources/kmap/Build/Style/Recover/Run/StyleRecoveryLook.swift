import Foundation

extension StyleRecovery {
    /// Which codes this map was seen drawing each meaning with, and over how much ground.
    static func ledger(_ evidence: Evidence, into report: inout Report, stop: StopFlag = StopFlag()) throws {
        // Each code tallied on its own, over every core: a code's areas add up in its own
        // order, as they always have, so the sums come out the same.
        let codes = Array(evidence.codes)
        let tallies = Lanes.map(codes.count, lanes: codes.count) { at in
            var counts: [String: Int] = [:]
            var areas: [String: Double] = [:]
            let code = codes[at].value
            var read = 0
            for (id, tags) in code.sources {
                read += 1
                if read % StyleRecovery.progressStride == 0, stop.isRaised { break }
                guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                counts[tag, default: 0] += 1
                if let area = code.extent[id] { areas[tag, default: 0] += area }
            }
            return (counts, areas)
        }
        // A code left part-tallied on a stop is thrown away with the rest.
        if stop.isRaised { throw CancellationError() }
        for (at, (key, _)) in codes.enumerated() {
            for (tag, count) in tallies[at].0 { report.codesByTag[tag, default: [:]][key] = count }
            for (tag, area) in tallies[at].1 { report.areaByTag[tag, default: [:]][key] = area }
        }
    }

    /// The TYP the map carries, for the silencing gate: only a code their TYP
    /// paints can paint the wrong thing. A map without a TYP silences nothing.
    static func typDefined(in img: URL) -> [ElementDumper.Kind: Set<Int>] {
        var typDefined: [ElementDumper.Kind: Set<Int>] = [:]
        let typScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString).typ")
        if ImgContainer.extractTYP(from: img, to: typScratch),
            let typ = try? TypBinary.read(typScratch)
        {
            typDefined[.area] = Set(typ.polygons.map(\.code))
            typDefined[.line] = Set(typ.lines.map(\.code))
            typDefined[.point] = Set(typ.points.map(\.code))
        }
        FileTools.removeIfPresent(typScratch)
        return typDefined
    }

    /// Their look on kmap's numbers, as a TYP source. The pictures come from the TYP
    /// the map carries; which lands on which of our numbers is the evidence's to say.
    /// Silent where there is nothing to recover, or no rules of ours to put it on.
    /// Our numbers are read from the neutral rules where given: the last build's own
    /// set carries its hides, and a hidden number would come out unpainted.
    static func recoverStyle(
        from img: URL,
        into report: inout Report,
        log: Log,
        rulesDirectory: URL?
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovered-\(UUID().uuidString).typ")
        defer { FileTools.removeIfPresent(scratch) }
        guard ImgContainer.extractTYP(from: img, to: scratch),
            let binary = try? TypBinary.read(scratch)
        else {
            log.append("the map carries no TYP — there is no look to recover")
            return
        }
        let theirs = TypSource.parse(TypDecompiler.source(binary))
        guard
            let rules = RuleSetIndex.read(
                styleDirectory: rulesDirectory ?? StyleCatalog.baseStyleDirectory
            )
        else {
            log.warn("kmap's own rules are not materialized yet — build once, then recover")
            return
        }
        // The zooms each code was seen at, so a ladder of theirs lands on ours.
        var zooms: [String: [Int: Int]] = [:]
        for (key, outcome) in report.outcomes { zooms[key] = outcome.resolutions }
        let ported = StylePort.map(
            codesByTag: report.codesByTag,
            rules: rules,
            theirZooms: zooms,
            theirTyp: theirs,
            theirAreas: report.areaByTag
        )
        report.codePage = theirs.codePage
        report.style = StylePort.typ(
            from: theirs,
            ported: ported,
            familyID: theirs.familyID,
            productID: theirs.productID,
            codePage: theirs.codePage,
            unstyled: StylePort.leftToTheDevice(
                codesByTag: report.codesByTag,
                rules: rules,
                theirTyp: theirs,
                ported: ported
            ),
            twinsAs: StylePort.twinsAs(StylePort.drawn(ported), rules: rules)
        )
        // Counted as the TYP has them: a port onto a ground number is drawn from the
        // ground's own section, and its picture is one no number of ours carries.
        let drawn = StylePort.drawn(ported)
        report.ported = Dictionary(grouping: drawn, by: \.kind).mapValues(\.count)
        report.contested = drawn.filter { !$0.rivals.isEmpty }
        report.uncovered = StylePort.uncovered(
            codesByTag: report.codesByTag,
            rules: rules,
            theirs: theirs,
            ported: drawn
        )
        let counted = report.ported.map { "\($0.value) \($0.key.plural)" }.sorted()
        log.append(
            counted.isEmpty
                ? "nothing recovered onto kmap's numbers"
                : "recovered " + counted.joined(separator: ", ") + " onto kmap's numbers"
        )
    }
}
