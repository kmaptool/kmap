import Foundation

/// The rule text a materialized style is shaped from: substitutions applied, ladders
/// fitted to the levels a build draws at, and blocks spliced in.
extension StyleCatalog {
    /// What a zoom plan adds to the materialized style's identity: the windows, not the
    /// plan's name - two plans with the same windows produce the same rules.
    func zoomTag(_ plan: ZoomPlan) -> String {
        guard plan.movesAnything else { return "" }
        let windows = plan.windows.sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value.rungs.lowerBound)-\($0.value.rungs.upperBound)" }
        return "+zoom-" + windows.joined(separator: ",")
    }

    /// Applies a substitution list - the `@@ file` / `- old` / `+ new` format shared by
    /// `redirects.txt` and `reassignments.txt` - to a materialized style. Matching is
    /// exact-line: a substitution that no longer matches is reported, not applied loosely.
    @discardableResult

    static func applySubstitutions(_ list: String, in directory: URL) throws
        -> (applied: Int, missed: [String], hidden: Int) {

        var edits: [String: [(old: String, new: [String])]] = [:]
        for entry in SubstitutionSheet.parse(list) where !entry.file.isEmpty {
            edits[entry.file, default: []].append((entry.old.joined(separator: "\n"), entry.new))
        }

        var applied = 0
        var missed: [String] = []
        var hidden = 0
        for (name, substitutions) in edits {
            let url = directory.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for substitution in substitutions {
                guard text.contains(substitution.old) else {
                    // The hide pass rewrites a rule's type line and leaves its mark; a
                    // substitution aimed at a hidden rule has nothing to retarget - the
                    // rule draws nothing - so the miss is bookkeeping, not a warning.
                    let condition = substitution.old
                        .components(separatedBy: " [0x").first ?? substitution.old
                    if let at = text.range(of: condition),
                       text[at.upperBound...].prefix(200).contains("# kmap: hidden") {
                        hidden += 1
                        continue
                    }
                    // A name literal the language pass rewrote does not unmake the rule:
                    // the same condition carrying the same type is the same rule, and
                    // only its type token is swapped.
                    if Self.retype(&text, old: substitution.old,
                                   new: substitution.new.joined(separator: "\n")) {
                        applied += 1
                    } else {
                        missed.append("\(name): \(truncate(substitution.old, to: 60))")
                    }
                    continue
                }
                text = text.replacingOccurrences(of: substitution.old,
                                                 with: substitution.new.joined(separator: "\n"))
                applied += 1
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return (applied, missed, hidden)
    }

    /// The resolutions a levels profile draws at, tiles and overview submap together:
    /// `0:24, 1:22` and `4:17, 5:16` give 24, 22, 17, 16.
    static func rungs(of levels: LevelsProfile) -> [Int] {
        (levels.levels + ", " + levels.overviewLevels)
            .split(separator: ",")
            .compactMap { Int($0.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) ?? "") }
            .sorted()
    }

    /// Fits every band of zooms in a style onto the ladder this build actually has.
    ///
    /// A borrowed style's bands come from its own map, whose ladder may hold rungs this
    /// build does not: a stroke pinned to `resolution 20-20` draws nothing where the
    /// ladder steps 21, 19. Each end is moved to the nearest rung there is, so the
    /// stroke lands on the zoom closest to where its author put it.
    static func fitBands(to ladder: [Int], in directory: URL) throws -> Int {
        guard !ladder.isEmpty else { return 0 }
        func nearest(_ value: Int) -> Int {
            ladder.min { a, b in
                let da = abs(a - value), db = abs(b - value)
                return da == db ? a < b : da < db
            } ?? value
        }
        var fitted = 0
        for name in ["lines", "polygons", "points"] {
            let url = directory.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A ladder's coarsest stroke reaches as far out as its rule does. The bands
            // come from the borrowed map, whose own ladder stops where its tiles stop;
            // ours goes further out, and a motorway that vanishes when you zoom out is
            // not what either style means. The rule says how far: the zoom plan has
            // already lowered the roads meant to survive the far view.
            text = reachOfLadders(in: text)
            var out: [String] = []
            for line in text.components(separatedBy: "\n") {
                guard let range = line.range(of: "resolution [0-9]+-[0-9]+",
                                             options: .regularExpression) else {
                    out.append(line)
                    continue
                }
                let numbers = line[range].split(separator: " ")[1].split(separator: "-")
                guard numbers.count == 2, let low = Int(numbers[0]),
                      let high = Int(numbers[1]) else { out.append(line); continue }
                // A band with a rung inside it already draws where it should.
                if ladder.contains(where: { $0 >= low && $0 <= high }) {
                    out.append(line)
                    continue
                }
                let fittedLow = nearest(low), fittedHigh = nearest(high)
                out.append(line.replacingCharacters(
                    in: range,
                    with: "resolution \(min(fittedLow, fittedHigh))-\(max(fittedLow, fittedHigh))"))
                fitted += 1
            }
            text = out.joined(separator: "\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return fitted
    }

    /// Extends each ladder's coarsest stroke down to the zoom its own rule reaches.
    ///
    /// The strokes of one rule sit directly above it, sharing its condition; the rule
    /// itself carries no band. Where the rule draws further out than its coarsest
    /// stroke, that stroke follows it down, so the road keeps its borrowed look at
    /// every zoom rather than falling back to the plain line.
    static func reachOfLadders(in text: String) -> String {
        func condition(of line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("[0x"), !trimmed.hasPrefix("#") else { return nil }
            let cut = trimmed.firstIndex(of: "{") ?? trimmed.firstIndex(of: "[")
                ?? trimmed.endIndex
            let head = String(trimmed[..<cut]).trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? nil : head
        }
        func band(of line: String) -> (low: Int, high: Int)? {
            guard let found = line.range(of: "resolution [0-9]+-[0-9]+",
                                         options: .regularExpression) else { return nil }
            let parts = line[found].split(separator: " ")[1].split(separator: "-")
            guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1])
            else { return nil }
            return (low, high)
        }
        func plainResolution(of line: String) -> Int? {
            guard band(of: line) == nil,
                  let found = line.range(of: "resolution [0-9]+",
                                         options: .regularExpression) else { return nil }
            return Int(line[found].split(separator: " ")[1])
        }

        var lines = text.components(separatedBy: "\n")
        var at = 0
        while at < lines.count {
            guard let head = condition(of: lines[at]) else { at += 1; continue }
            var end = at
            while end + 1 < lines.count, condition(of: lines[end + 1]) == head { end += 1 }
            defer { at = end + 1 }
            guard end > at else { continue }
            // The rule of the group: the one drawn without a band.
            guard let reach = lines[at...end].compactMap(plainResolution).min()
            else { continue }
            var lowest: (index: Int, low: Int, high: Int)?
            for index in at...end {
                guard let band = band(of: lines[index]) else { continue }
                if lowest == nil || band.low < lowest!.low {
                    lowest = (index, band.low, band.high)
                }
            }
            guard let lowest, reach < lowest.low else { continue }
            lines[lowest.index] = lines[lowest.index].replacingOccurrences(
                of: "resolution [0-9]+-[0-9]+",
                with: "resolution \(reach)-\(lowest.high)",
                options: .regularExpression)
        }
        return lines.joined(separator: "\n")
    }

    /// The language-proof fallback for one substitution.
    ///
    /// A sheet is derived against the pristine rule set, where labels are English and
    /// the zoom plan has not moved anything; it is applied to the rules this build
    /// actually has, where a label may read `Брод` and a rule may sit at another
    /// resolution. Exact-line matching then misses a rule that is plainly the same
    /// one, so it is found here by what cannot drift: the bare condition, and the type
    /// it emits.
    ///
    /// Three shapes are honoured - a rule deleted, a rule re-aimed, and a rule kept
    /// with strokes stacked above it. Anything else is left to the exact match, and
    /// reported when that misses.
    private static func retype(_ text: inout String, old: String, new: String) -> Bool {
        func token(of rule: String) -> Substring? {
            guard let open = rule.range(of: "[0x") else { return nil }
            return rule[open.lowerBound...].prefix(while: { $0 != " " && $0 != "]" })
        }
        func bareCondition(of rule: String) -> String? {
            let first = rule.split(separator: "\n").first.map(String.init) ?? rule
            let cut = first.firstIndex(of: "{") ?? first.firstIndex(of: "[")
                ?? first.endIndex
            let condition = String(first[..<cut]).trimmingCharacters(in: .whitespaces)
            return condition.isEmpty ? nil : condition
        }
        guard let oldToken = token(of: old), let condition = bareCondition(of: old)
        else { return false }

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // Every replacement line must be about the same rule, or this substitution is
        // doing more than the fallback understands.
        guard newLines.allSatisfy({ line in
            line.contains("[0x") ? bareCondition(of: line) == condition : true
        }) else { return false }

        var lines = text.components(separatedBy: "\n")
        for at in lines.indices {
            // The whole condition, not a prefix: `highway=motorway` must not land on
            // `highway=motorway & mkgmap:fast_road=yes`.
            guard bareCondition(of: lines[at]
                .trimmingCharacters(in: .whitespaces)) == condition else { continue }
            // The type may sit on this line or, for a two-line rule, on the next.
            guard let target = [at, at + 1].first(where: {
                $0 < lines.count && lines[$0].contains(oldToken)
            }) else { continue }

            // The rule's own resolution here and now: an unbanded stroke follows it, so
            // the stack appears and vanishes as one.
            let here = lines[target].range(of: "resolution [0-9-]+",
                                           options: .regularExpression)
                .map { String(lines[target][$0]) }
            func fitted(_ line: String) -> String {
                // A stroke is paint, not meaning: the name belongs to the rule below
                // it, which sets it whatever language this build speaks. A label
                // carried up from the sheet would be the untranslated one.
                //
                // The block is taken by hand rather than by pattern: `${name}` puts a
                // closing brace inside it, and a lazy match ends there.
                var out = line
                if let open = out.firstIndex(of: "{"),
                   let type = out.range(of: "[0x"),
                   let close = out[open..<type.lowerBound].lastIndex(of: "}") {
                    let block = open...close
                    let kept = out[block].dropFirst().dropLast()
                        .split(separator: ";")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.hasPrefix("name ") && !$0.hasPrefix("add name")
                                  && !$0.hasPrefix("set name") }
                    out = out.replacingCharacters(
                        in: block,
                        with: kept.isEmpty ? "" : "{" + kept.joined(separator: "; ") + "}")
                    while out.contains("  ") {
                        out = out.replacingOccurrences(of: "  ", with: " ")
                    }
                }
                // A stroke pinned to a band of zooms keeps it: the band is where that
                // stroke belongs, and the rule's own resolution says nothing about it.
                guard let here, out.range(of: "resolution [0-9]+-[0-9]+",
                                          options: .regularExpression) == nil
                else { return out }
                return out.replacingOccurrences(of: "resolution [0-9-]+", with: here,
                                                options: .regularExpression)
            }

            guard !newLines.isEmpty else {
                // Silenced: the rule and its second line go.
                lines.removeSubrange(at...(min(target, lines.count - 1)))
                text = lines.joined(separator: "\n")
                return true
            }
            // The last replacement line is the rule itself, re-aimed or unchanged; the
            // ones before it are strokes stacked above.
            guard let closing = newLines.last, let newToken = token(of: closing)
            else { return false }
            let layers = newLines.dropLast(oldLines.count == newLines.count ? 1
                                           : oldLines.count).map(fitted)
            lines[target] = lines[target].replacingOccurrences(of: String(oldToken),
                                                               with: String(newToken))
            // A rule the sheet has pinned to a band takes that band: the strokes above
            // it own the other zooms, and leaving its own `resolution N` - which means
            // N and every zoom finer - would draw it under each of them as well, a
            // river once in its own colour and again in the stroke's. Never coarser
            // than this build already draws the rule: the zoom plan has had its say.
            if let band = closing.range(of: "resolution [0-9]+-[0-9]+",
                                        options: .regularExpression),
               lines[target].range(of: "resolution [0-9]+-[0-9]+",
                                   options: .regularExpression) == nil {
                let edges = closing[band].split(separator: " ")[1].split(separator: "-")
                let own = here.flatMap { Int($0.split(separator: " ")[1]) }
                if edges.count == 2, let low = Int(edges[0]), let high = Int(edges[1]),
                   max(low, own ?? low) <= high {
                    lines[target] = lines[target].replacingOccurrences(
                        of: "resolution [0-9-]+",
                        with: "resolution \(max(low, own ?? low))-\(high)",
                        options: .regularExpression)
                }
            }
            // Above the rule, which stops the chain: a stroke pinned to a band does
            // not match outside it, and a rule left looking would run on into whatever
            // the rules below draw.
            if !layers.isEmpty { lines.insert(contentsOf: layers, at: at) }
            text = lines.joined(separator: "\n")
            return true
        }
        return false
    }

    /// Inserts a block of rules ahead of `<finalize>`, or appends it where there is none.
    /// A `<finalize>` section may hold only actions; a type definition after it is an error.
    func splice(_ rules: String, into text: inout String) {
        if let finalize = text.range(of: "\n<finalize>") {
            text.replaceSubrange(finalize, with: rules + "\n<finalize>")
        } else {
            text += rules
        }
    }
}
