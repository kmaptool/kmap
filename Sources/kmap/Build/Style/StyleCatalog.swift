import Foundation

/// Materializes styles on disk for mkgmap to consume: the base rule set with kmap's
/// rewrites, the choices of one build, and the shipped palettes' TYP files. Discovery of
/// what can be built with lives in `StyleDiscovery`; the rewrites themselves in the
/// `StyleRules*` files.
final class StyleCatalog {

    /// The generated land layer's type, named once for the style rule that emits it and
    /// the compile stage that clips it to the tile exactly.
    static let landPolygonType = "0x27"

    /// The contour line types, from `inc/contour_lines`: minor, medium, major.
    ///
    /// Named here because the compile stage lets them run past a tile frame, into the
    /// overlap band: a contour is drawn and never routed.
    static let contourLineTypes = ["0x20", "0x21", "0x22"]

    /// Bump when the materialized style layout changes, to force a refresh.
    private static let materializedVersion = "84"

    private let settings: SettingsStore
    private let toolchain: Toolchain

    init(settings: SettingsStore, toolchain: Toolchain) {
        self.settings = settings
        self.toolchain = toolchain
    }

    /// The rule set every kmap style shares: mkgmap's default rules with metric contours.
    static var baseStyleDirectory: URL { Paths.styles.appendingPathComponent("kmap-base", isDirectory: true) }

    // MARK: Materialization

    enum StyleError: Error, LocalizedError {
        case noMkgmap
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMkgmap: return t("mkgmap.jar is needed to unpack the base style")
            case .extractionFailed(let m): return t("could not unpack the base style: %@", m)
            }
        }
    }

    /// Runs `body` with the styles directory held against other kmap processes.
    ///
    /// The lock is advisory and process-wide; the only writer is style materialization.
    private func holdingStyles<T>(_ body: () throws -> T) rethrows -> T {
        Paths.ensure(Paths.styles)
        return try FileLock.holding(Paths.styles.appendingPathComponent(".lock"), body)
    }

    /// A private copy of a prepared style, taken under the styles lock.
    ///
    /// mkgmap reads the style throughout its run, so a build must not read the shared
    /// directory, which a concurrent build may rewrite.
    func snapshot(_ directory: URL, to destination: URL) throws {
        try holdingStyles {
            FileTools.removeIfPresent(destination)
            try FileManager.default.copyItem(at: directory, to: destination)
        }
    }

    /// A directory to build a style in before it is swapped into place. Hidden, so the
    /// style list, which takes any folder holding a `lines` file, does not show it.
    static func stagingDirectory(for what: String) -> URL {
        Paths.ensure(Paths.styles)
        return Paths.styles.appendingPathComponent(
            ".\(what)-build-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Puts a finished build where the style lives, in one step.
    ///
    /// The marker is written before the swap, so `dir` holds either a complete stamped
    /// style or the previous one.
    private func install(_ build: URL, as dir: URL, marker wanted: String) throws {
        try wanted.write(to: build.appendingPathComponent("kmap-version"),
                         atomically: true, encoding: .utf8)
        try holdingStyles {
            FileTools.removeIfPresent(dir)
            try FileManager.default.moveItem(at: build, to: dir)
        }
    }

    /// Whether `dir` already holds a style stamped `wanted`, read under the lock so a
    /// swap in progress is seen either whole or not at all.
    private func isMaterialized(_ dir: URL, as wanted: String) -> Bool {
        let marker = dir.appendingPathComponent("kmap-version")
        let current = holdingStyles { try? String(contentsOf: marker, encoding: .utf8) }
        return current?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            && FileTools.exists(dir.appendingPathComponent("lines"))
    }

    /// Everything the materialized rules depend on, in one string: version, description
    /// carrier, zoom plan, label language, hides and reassignments. Derived styles are
    /// copies of the base, so their markers carry it too.
    private func materializedIdentity(_ choices: StyleChoices) -> String {
        let hidden = choices.hidden
        let hiddenTag = hidden.isEmpty ? "" : "+hide-" + hidden.sorted().joined(separator: "-")
        return StyleCatalog.materializedVersion
            + (choices.descriptions == .off ? "" : "+desc-\(choices.descriptions.rawValue)")
            + zoomTag(choices.zoom.plan)
            + (choices.cyrillic ? "+ru" : "")
            + hiddenTag
            + RuleReassignments.fingerprint()
    }

    private func materializeBaseStyle(_ choices: StyleChoices, log: Log,
                                      runner: ProcessRunner) async throws {
        let dir = StyleCatalog.baseStyleDirectory
        let marker = dir.appendingPathComponent("kmap-version")
        let wanted = materializedIdentity(choices)

        // Read under the lock, so a swap in progress is seen whole or not at all.
        let current = holdingStyles { try? String(contentsOf: marker, encoding: .utf8) }
        if let current, current.trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
           FileTools.exists(dir.appendingPathComponent("lines")),
           // The hide catalogue is made from these rules and kept beside them; without it
           // the style is unpacked again.
           FileTools.exists(HideableCatalogue.url) {
            return
        }

        // Built beside the shared directory and swapped in whole: the lock cannot be held
        // across the unpack, which awaits a child process.
        let build = StyleCatalog.stagingDirectory(for: "base")
        defer { FileTools.removeIfPresent(build) }
        try await materializeRules(into: build, descriptions: choices.descriptions,
                                   cyrillicLabels: choices.cyrillic, log: log, runner: runner)
        // Recorded here, where the rules are complete and no build choice has touched
        // them: the call below shifts resolutions and applies hides.
        let listed = HideableCatalogue.record(pointsAt: build.appendingPathComponent("points"))
        if listed > 0 { log.append("\(listed) hideable feature(s) catalogued from this style") }

        try materializeChoices(in: build, choices: choices, log: log)

        // Translation goes last, after every exact-line substitution: the icon redirects
        // and the hideable entries quote the English label text verbatim.
        try dropOperatorFromNamedLabels(in: build, log: log)
        try translateDefaultNames(in: build, cyrillic: choices.cyrillic, log: log)
        try addRussianLabels(in: build, cyrillic: choices.cyrillic, log: log)

        try install(build, as: dir, marker: wanted)
        log.ok("base rule set ready at \(Paths.display(dir))")
    }

    /// Unpacks mkgmap's own `styles/default` into `dir`, with kmap's metric contours.
    private func unpackStockStyle(into dir: URL, log: Log, runner: ProcessRunner) async throws {
        guard let mkgmap = toolchain.findMkgmap()?.url else { throw StyleError.noMkgmap }
        log.step("unpacking the base rule set from mkgmap")

        let staging = Paths.styles.appendingPathComponent("unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }

        guard let archive = Archive.current else {
            throw StyleError.extractionFailed(Archive.missingNote())
        }
        let unpack = archive.unpack(mkgmap, into: staging, matching: ["styles/default/*"])
        try await runner.run(unpack.executable, unpack.arguments) { line in
            log.output(line)
        }

        let extracted = staging.appendingPathComponent("styles/default")
        guard FileTools.exists(extracted.appendingPathComponent("lines")) else {
            throw StyleError.extractionFailed("styles/default was not found inside \(mkgmap.lastPathComponent)")
        }

        FileTools.removeIfPresent(dir)
        Paths.ensure(Paths.styles)
        try FileManager.default.moveItem(at: extracted, to: dir)

        // Contours in metres, not feet.
        let incDir = dir.appendingPathComponent("inc", isDirectory: true)
        Paths.ensure(incDir)
        try StyleAssets.contourLinesMetric.write(
            to: incDir.appendingPathComponent("contour_lines"), atomically: true, encoding: .utf8)
    }

    /// The rule set before any build choice: the unpack from mkgmap, kmap's own rules, the
    /// icon redirects, the reassignments and the description rules. Hiding, the POI zoom
    /// shift and the label translation come after, in `materializeChoices`.
    ///
    /// The additions run in a fixed order. Three constraints hold it together, each noted
    /// where it binds: the barrier-access rules anchor on the block the barrier split
    /// writes, the found rules are fallbacks and go last, and the redirects and
    /// reassignments match the text every earlier call has finished shaping.
    /// The rules as they stand before any build choice touches them — descriptions
    /// off, labels untranslated, nothing hidden. Recovery derives its sheet against
    /// this stage, and the recovered style applies the sheet at this same stage, so a
    /// sheet never inherits one build's personal preferences and survives them all.
    /// The caller owns the returned directory.
    func neutralRulesForRecovery(log: Log, runner: ProcessRunner) async throws -> URL {
        let dir = StyleCatalog.stagingDirectory(for: "neutral")
        try await materializeRules(into: dir, descriptions: .off, cyrillicLabels: false,
                                   log: log, runner: runner)
        return dir
    }

    func materializeRules(into dir: URL,
                          descriptions: BuildRecipe.DescriptionCarrier,
                          cyrillicLabels: Bool,
                          log: Log, runner: ProcessRunner) async throws {
        try await unpackStockStyle(into: dir, log: log, runner: runner)

        try addRepairLinkRule(in: dir, log: log)
        try busStopsBeforePlatforms(in: dir, log: log)
        try patchPeakLabel(in: dir, cyrillic: cyrillicLabels, log: log)
        try addAreaPOIFilter(in: dir, log: log)
        try addProtectedAreaRules(in: dir, log: log)
        try addCliffRules(in: dir, log: log)
        try addGroundCoverRules(in: dir, log: log)
        try addLandUnderEverything(in: dir, log: log)
        try lowerWoodlandResolution(in: dir, log: log)
        try addForestTypeRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addPlateauEdgeRules(in: dir, log: log)
        try addParkingRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addLandformRules(in: dir, log: log)
        try addAerialwayRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addTerrainPOIRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addWaterSourceRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addSpringVariantRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try splitBarrierRule(in: dir, log: log)
        // After the split: it anchors on the block that call writes.
        try addBarrierAccessRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addTrailWarningRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addGenericAddressRules(in: dir, log: log)
        // Last of the rule additions: these are fallbacks for meanings no earlier rule
        // claims, and must not fire before those rules.
        try addFoundPointRules(in: dir, log: log)
        try addFoundLineRules(in: dir, log: log)
        try addFoundPolygonRules(in: dir, log: log)
        // Last of all: it edits rules the passes above may have written.
        try widenDrawnVocabulary(in: dir, log: log)

        try StyleAssets.styleInfo.write(
            to: dir.appendingPathComponent("info"), atomically: true, encoding: .utf8)

        let redirects = try StyleCatalog.applySubstitutions(StyleAssets.iconRedirects, in: dir)
        if redirects.applied > 0 {
            log.append("\(redirects.applied) icon redirect(s) applied")
        }
        for miss in redirects.missed {
            log.warn("icon redirect did not match this mkgmap's style — \(miss)")
        }

        // Locally configured reassignments, after kmap's; same exact-line mechanism.
        if !RuleReassignments.isEmpty() {
            let mine = try StyleCatalog.applySubstitutions(RuleReassignments.text(), in: dir)
            if mine.applied > 0 {
                log.ok("\(mine.applied) of your type reassignment(s) applied")
            }
            for miss in mine.missed {
                log.warn("your reassignment did not match this mkgmap's style — \(miss)")
            }
        }

        try addDescriptionRules(in: dir, carrier: descriptions, log: log)
    }

    /// Applies the build's own choices to a finished rule set: what to leave off, and how
    /// far to pull the POIs in.
    private func materializeChoices(in dir: URL, choices: StyleChoices, log: Log) throws {
        // Hiding must come before the zoom plan: a hide is an exact-line substitution, and
        // the plan rewrites `resolution 24` in the very lines the hides match.
        try hideFeatures(choices.hidden, in: dir, log: log)
        try applyZoomPlan(choices.zoom.plan, levels: choices.zoom.levels, in: dir, log: log)
        try showTrailsEarlier(in: dir, log: log)
        try thinTheOverview(in: dir, cyrillic: choices.cyrillic, log: log)
    }

    /// What a zoom plan adds to the materialized style's identity: the windows, not the
    /// plan's name — two plans with the same windows produce the same rules.
    func zoomTag(_ plan: ZoomPlan) -> String {
        guard plan.movesAnything else { return "" }
        let windows = plan.windows.sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value.rungs.lowerBound)-\($0.value.rungs.upperBound)" }
        return "+zoom-" + windows.joined(separator: ",")
    }

    /// Applies a substitution list — the `@@ file` / `- old` / `+ new` format shared by
    /// `redirects.txt` and `reassignments.txt` — to a materialized style. Matching is
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
                    // substitution aimed at a hidden rule has nothing to retarget — the
                    // rule draws nothing — so the miss is bookkeeping, not a warning.
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
    /// Three shapes are honoured — a rule deleted, a rule re-aimed, and a rule kept
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
            // it own the other zooms, and leaving its own `resolution N` — which means
            // N and every zoom finer — would draw it under each of them as well, a
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

    /// Builds the rule set for a style whose codes were recovered from its map: the base
    /// rules with the sheet's reassignments applied. The sheet's hash is part of the
    /// materialized identity, so recovering again rebuilds the rules.
    private func materializeRecoveredStyle(_ style: MapStyle, choices: StyleChoices,
                                           log: Log, runner: ProcessRunner) async throws {
        try await materializeBaseStyle(choices, log: log, runner: runner)
        guard let typ = style.typURL, let dir = style.styleDirectory,
              let sheetURL = TypLibrary.sheet(of: typ),
              let sheet = try? String(contentsOf: sheetURL, encoding: .utf8) else { return }

        let wanted = materializedIdentity(choices)
            + "+sheet-\(TypLibrary.fingerprint(Data(sheet.utf8)))"
        if isMaterialized(dir, as: wanted) { return }

        // The whole base pipeline again, with the sheet slotted in at its own place:
        // after the choices — hides and zoom shifts anchor on the original rule text,
        // so they go first, and a sheet miss on a hidden rule is bookkeeping — and
        // before the translations, which rewrite the label literals the sheet's
        // anchors carry. A zoom-shifted rule differs only in its resolution, which
        // the condition-and-type fallback sees through.
        let build = StyleCatalog.stagingDirectory(for: "recovered")
        defer { FileTools.removeIfPresent(build) }
        try await materializeRules(into: build, descriptions: choices.descriptions,
                                   cyrillicLabels: choices.cyrillic, log: log,
                                   runner: runner)
        try materializeChoices(in: build, choices: choices, log: log)
        let result = try StyleCatalog.applySubstitutions(sheet, in: build)
        let ladder = StyleCatalog.rungs(of: choices.zoom.levels)
        let fitted = try StyleCatalog.fitBands(to: ladder, in: build)
        if fitted > 0 {
            log.append("\(fitted) zoom band(s) fitted onto this build's ladder")
        }
        try dropOperatorFromNamedLabels(in: build, log: log)
        try translateDefaultNames(in: build, cyrillic: choices.cyrillic, log: log)
        try addRussianLabels(in: build, cyrillic: choices.cyrillic, log: log)
        try install(build, as: dir, marker: wanted)
        log.ok("recovered rule set ready — \(result.applied) reassignment(s) applied")
        if result.hidden > 0 {
            log.append("\(result.hidden) reassignment(s) aimed at rules this build hides"
                       + " — nothing to retarget")
        }
        for miss in result.missed {
            log.warn("recovered reassignment did not match this mkgmap's style — \(miss)")
        }
    }

    /// Prepares whatever the chosen style needs before a build.
    func prepare(_ style: MapStyle, log: Log, runner: ProcessRunner,
                 descriptions: BuildRecipe.DescriptionCarrier = .off,
                 hidden: Set<String> = [],
                 zoom: (plan: ZoomPlan, levels: LevelsProfile) = (.asMeasured, .smooth),
                 cyrillicLabels: Bool = false) async throws {
        let choices = StyleChoices(descriptions: descriptions, hidden: hidden,
                                   zoom: zoom, cyrillic: cyrillicLabels)
        if style.styleDirectory?.lastPathComponent.hasPrefix("recovered-") == true {
            try await materializeRecoveredStyle(style, choices: choices,
                                                log: log, runner: runner)
        }
        // Written unconditionally, keeping the file in step with the binary's palette
        // without a version marker.
        if let shipped = StyleCatalog.shippedPalette(id: style.id) {
            try holdingStyles {
                try StyleCatalog.shippedTypText(of: shipped)
                    .write(to: StyleCatalog.shippedTypURL(of: shipped),
                           atomically: true, encoding: .utf8)
            }
        }
        if style.styleDirectory == StyleCatalog.baseStyleDirectory {
            try await materializeBaseStyle(choices, log: log, runner: runner)
        }
    }

}
