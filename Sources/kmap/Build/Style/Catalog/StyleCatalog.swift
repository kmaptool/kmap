import Foundation

/// Materializes styles on disk for mkgmap to consume: the base rule set with kmap's
/// rewrites, the choices of one build, and the shipped palettes' TYP files. Discovery of
/// what can be built with lives in `StyleDiscovery`; the rewrites themselves in the
/// `StyleRules*` files.
final class StyleCatalog: Sendable {
    /// The generated land layer's type, named once for the style rule that emits it and
    /// the compile stage that clips it to the tile exactly.
    static let landPolygonType = "0x27"

    /// The contour line types, from `inc/contour_lines`: minor, medium, major.
    ///
    /// Named here because the compile stage lets them run past a tile frame, into the
    /// overlap band: a contour is drawn and never routed.
    static let contourLineTypes = ["0x20", "0x21", "0x22"]
    /// The same, as the numbers they are.
    static let contourLineCodes = Set(contourLineTypes.compactMap { Int($0.dropFirst(2), radix: 16) })

    /// Bump when the materialized style layout changes, to force a refresh. kmap's own
    /// version is in the identity too, so a release that forgot to bump still refreshes.
    private static let materializedVersion = "94"

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
        case usersOwnFolder(String)
        case sheetUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .noMkgmap: return t("mkgmap.jar is needed to unpack the base style")
            case .extractionFailed(let m): return t("could not unpack the base style: %@", m)
            case .usersOwnFolder(let path):
                return t("%@ is a folder of your own, which kmap does not replace: rename it", path)
            case .sheetUnreadable(let path):
                return t("the reassignment sheet %@ cannot be read", path)
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
    ///
    /// - Returns: false where `expecting` is given and the copy carries another marker:
    ///   another build swapped the shared style since this one prepared it.
    @discardableResult
    func snapshot(_ directory: URL, to destination: URL, expecting: String? = nil) throws -> Bool {
        try holdingStyles {
            FileTools.removeIfPresent(destination)
            // The folder a link leads to: copied as a link, the build's rule edits would
            // write through it into the user's own files.
            do {
                try FileTools.copy(FileTools.resolvingLinks(directory), to: destination)
            } catch {
                // A copy cut short would be compiled as if it were the style.
                FileTools.removeIfPresent(destination)
                throw error
            }
            guard let expecting else { return true }
            let marker = try? String(contentsOf: destination.appendingPathComponent("kmap-version"), encoding: .utf8)
            return marker?.trimmingCharacters(in: .whitespacesAndNewlines) == expecting
        }
    }

    /// The marker the rules prepared for `style` with `choices` carry, for the styles kmap
    /// materializes into a shared folder; nil for one it does not.
    func expectedMarker(for style: MapStyle, choices: StyleChoices) -> String? {
        if style.styleDirectory == StyleCatalog.baseStyleDirectory { return materializedIdentity(choices) }
        guard case .importedTYP = style.origin, let typ = style.typURL,
            style.styleDirectory?.lastPathComponent.hasPrefix("recovered-") == true,
            let sheetURL = TypLibrary.sheet(of: typ),
            let sheet = try? String(contentsOf: sheetURL, encoding: .utf8)
        else { return nil }
        return materializedIdentity(choices, fittedToLadder: true)
            + "+sheet-\(TypLibrary.fingerprint(Data(sheet.utf8)))"
    }

    /// What a killed run left: hidden build folders and unpackings a day old, so none another
    /// kmap is filling now, and rule sets a swap set aside, settled under the styles lock.
    static func removeAbandonedStaging(in styles: URL = Paths.styles, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: styles, includingPropertiesForKeys: nil)) ?? []
        FileLock.holding(styles.appendingPathComponent(".lock")) {
            for entry in entries where isSwappedOut(entry.lastPathComponent) {
                let original = entry.deletingLastPathComponent()
                    .appendingPathComponent(String(entry.lastPathComponent.dropFirst().dropLast(".old".count)))
                if FileTools.exists(original) {
                    FileTools.removeIfPresent(entry)
                } else {
                    try? FileTools.move(entry, to: original)
                }
            }
        }
        for entry in entries {
            let name = entry.lastPathComponent
            guard
                (name.hasPrefix(".") && name.contains("-build-")) || isUnpacking(name)
                    || name.hasPrefix(".hideable-"),
                let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 86_400
            else { continue }
            FileTools.removeIfPresent(entry)
        }
    }

    /// A directory to build a style in before it is swapped into place. Hidden, so the
    /// style list, which takes any folder holding a `lines` file, does not show it.
    static func stagingDirectory(for what: String) -> URL {
        Paths.ensure(Paths.styles)
        return Paths.styles.appendingPathComponent(
            ".\(what)-build-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }

    /// Puts a finished build where the style lives, in one step.
    ///
    /// The marker is written before the swap, so `dir` holds either a complete stamped
    /// style or the previous one.
    private func install(_ build: URL, as dir: URL, marker wanted: String) throws {
        try FileTools.write(wanted, to: build.appendingPathComponent("kmap-version"))
        try holdingStyles {
            // A folder without kmap's marker is the user's, named like a recovered style.
            if dir.lastPathComponent.hasPrefix("recovered-"), FileTools.exists(dir),
                !FileTools.exists(dir.appendingPathComponent("kmap-version"))
            {
                throw StyleError.usersOwnFolder(Paths.display(dir))
            }
            try FileTools.replace(dir, with: build, aside: Self.swappedOut)
        }
    }

    /// Where a swap keeps the rule set it replaces: hidden, so it is never listed, and
    /// never a name a user's own folder has.
    static func swappedOut(_ dir: URL) -> URL {
        dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent).old", isDirectory: true)
    }

    /// Whether `dir` already holds a style stamped `wanted`, read under the lock so a
    /// swap in progress is seen either whole or not at all.
    private func isMaterialized(_ dir: URL, as wanted: String) -> Bool {
        let marker = dir.appendingPathComponent("kmap-version")
        let current = holdingStyles { try? String(contentsOf: marker, encoding: .utf8) }
        return current?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            && FileTools.exists(dir.appendingPathComponent("lines"))
    }

    /// Everything the materialized rules depend on, as 1 string. The ladder counts only
    /// where something is fitted to it: a plan that moves a rule, or a recovered sheet.
    func materializedIdentity(_ choices: StyleChoices, fittedToLadder: Bool = false) -> String {
        let hidden = choices.hidden
        let hiddenTag = hidden.isEmpty ? "" : "+hide-" + hidden.sorted().joined(separator: "-")
        return StyleCatalog.materializedVersion + "+kmap-\(Version.number)"
            + (choices.descriptions == .off ? "" : "+desc-\(choices.descriptions.rawValue)")
            + zoomTag(choices.zoom.plan)
            + (fittedToLadder || choices.zoom.plan.movesAnything ? "+lv-\(choices.zoom.levels.id)" : "")
            + (choices.cyrillic ? "+ru" : "")
            + hiddenTag
            + RuleReassignments.fingerprint()
    }

    private func materializeBaseStyle(
        _ choices: StyleChoices,
        log: Log,
        runner: ProcessRunner
    ) async throws {
        let dir = StyleCatalog.baseStyleDirectory
        let marker = dir.appendingPathComponent("kmap-version")
        let wanted = materializedIdentity(choices)
        StyleCatalog.removeAbandonedStaging()

        // Read under the lock, so a swap in progress is seen whole or not at all.
        let current = holdingStyles { try? String(contentsOf: marker, encoding: .utf8) }
        if let current, current.trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
            FileTools.exists(dir.appendingPathComponent("lines")),
            // The hide catalogue is made from these rules and kept beside them; without it
            // the style is unpacked again.
            FileTools.exists(HideableCatalogue.url)
        {
            return
        }

        // Built beside the shared directory and swapped in whole: the lock cannot be held
        // across the unpack, which awaits a child process.
        let build = StyleCatalog.stagingDirectory(for: "base")
        defer { FileTools.removeIfPresent(build) }
        try await materializeRules(
            into: build,
            descriptions: choices.descriptions,
            cyrillicLabels: choices.cyrillic,
            log: log,
            runner: runner
        )
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
        try applyUserReassignments(in: build, log: log)

        try install(build, as: dir, marker: wanted)
        log.ok("base rule set ready at \(Paths.display(dir))")
    }

    /// Unpacks mkgmap's own `styles/default` into `dir`, with kmap's metric contours.
    private func unpackStockStyle(into dir: URL, log: Log, runner: ProcessRunner) async throws {
        guard let mkgmap = toolchain.findMkgmap()?.url else { throw StyleError.noMkgmap }
        log.step("unpacking the base rule set from mkgmap")

        let staging = Paths.styles.appendingPathComponent(".unpack-\(UUID().uuidString.prefix(8))")
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
        try FileTools.move(extracted, to: dir)

        // Contours in metres, not feet.
        let incDir = dir.appendingPathComponent("inc", isDirectory: true)
        Paths.ensure(incDir)
        try FileTools.write(StyleAssets.contourLinesMetric, to: incDir.appendingPathComponent("contour_lines"))
    }

    /// The rules before any build choice touches them: descriptions off, labels untranslated,
    /// nothing hidden. Recovery derives its sheet against this stage and the recovered style
    /// applies it here too, so a sheet never inherits one build's preferences. The caller owns
    /// the returned directory.
    func neutralRulesForRecovery(log: Log, runner: ProcessRunner) async throws -> URL {
        let dir = StyleCatalog.stagingDirectory(for: "neutral")
        do {
            try await materializeRules(
                into: dir,
                descriptions: .off,
                cyrillicLabels: false,
                log: log,
                runner: runner
            )
        } catch {
            FileTools.removeIfPresent(dir)
            throw error
        }
        return dir
    }

    /// The rule set before any build choice: the unpack from mkgmap, kmap's own rules, the
    /// icon redirects and the description rules. Hiding, the zoom plan and the label
    /// translation come after, and the user's own reassignments last.
    ///
    /// The additions run in a fixed order, each constraint noted where it binds: the
    /// barrier-access rules anchor on the block the barrier split writes, the found rules are
    /// fallbacks and go last, and the redirects match the text every earlier call has shaped.
    func materializeRules(
        into dir: URL,
        descriptions: BuildRecipe.DescriptionCarrier,
        cyrillicLabels: Bool,
        log: Log,
        runner: ProcessRunner
    ) async throws {
        try await unpackStockStyle(into: dir, log: log, runner: runner)

        try applyRulePasses(in: dir, cyrillicLabels: cyrillicLabels, log: log)

        try FileTools.write(StyleAssets.styleInfo, to: dir.appendingPathComponent("info"))

        let redirects = try StyleCatalog.applySubstitutions(StyleAssets.iconRedirects, in: dir)
        if redirects.applied > 0 {
            log.append("\(redirects.applied) icon redirect(s) applied")
        }
        for miss in redirects.missed {
            log.warn("icon redirect did not match this mkgmap's style — \(miss)")
        }

        try addDescriptionRules(in: dir, carrier: descriptions, cyrillic: cyrillicLabels, log: log)
    }

    /// The user's own reassignments, last of all: taken from the finished rules the editor
    /// shows, so they match the same text. A rule another build's choices moved is found by
    /// its condition and type.
    private func applyUserReassignments(in dir: URL, log: Log) throws {
        guard !RuleReassignments.isEmpty() else { return }
        let mine = try StyleCatalog.applySubstitutions(RuleReassignments.text(), in: dir)
        if mine.applied > 0 {
            log.ok("\(mine.applied) of your type reassignment(s) applied")
        }
        for miss in mine.missed {
            log.warn("your reassignment did not match this mkgmap's style — \(miss)")
        }
    }

    /// Every kmap rule pass over an unpacked stock style, in the order that matters: a
    /// later pass may anchor on what an earlier one wrote. Apart from `materializeRules`
    /// so that the order can be run without mkgmap.
    func applyRulePasses(in dir: URL, cyrillicLabels: Bool, log: Log) throws {
        try addRepairLinkRule(in: dir, log: log)
        try busStopsBeforePlatforms(in: dir, log: log)
        try patchPeakLabel(in: dir, cyrillic: cyrillicLabels, log: log)
        try splitInternetAccess(in: dir, log: log)
        try labelSportValues(in: dir, cyrillic: cyrillicLabels, log: log)
        try addAreaPOIFilter(in: dir, log: log)
        try addProtectedAreaRules(in: dir, log: log)
        try addCliffRules(in: dir, log: log)
        try addGroundCoverRules(in: dir, log: log)
        try addLandUnderEverything(in: dir, log: log)
        try lowerWoodlandResolution(in: dir, log: log)
        try addForestTypeRules(in: dir, cyrillic: cyrillicLabels, log: log)
        try addScrubFloor(in: dir, log: log)
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
    }

    /// Applies the build's own choices to a finished rule set: what to leave off, and how
    /// far to pull the POIs in.
    func materializeChoices(in dir: URL, choices: StyleChoices, log: Log) throws {
        // Hiding, then the trail and overview passes, all exact-line matches, before the zoom
        // plan, which rewrites `resolution 24` in those very lines; the plan then measures the
        // rules where a build without a plan draws them.
        try hideFeatures(choices.hidden, in: dir, log: log)
        try showTrailsEarlier(in: dir, log: log)
        try thinTheOverview(in: dir, cyrillic: choices.cyrillic, log: log)
        try applyZoomPlan(choices.zoom.plan, levels: choices.zoom.levels, in: dir, log: log)
    }

    /// Builds the rule set for a style whose codes were recovered from its map: the base
    /// rules with the sheet's reassignments applied. The sheet's hash is part of the
    /// materialized identity, so recovering again rebuilds the rules.
    private func materializeRecoveredStyle(
        _ style: MapStyle,
        choices: StyleChoices,
        log: Log,
        runner: ProcessRunner
    ) async throws {
        try await materializeBaseStyle(choices, log: log, runner: runner)
        guard let typ = style.typURL, let dir = style.styleDirectory, let sheetURL = TypLibrary.sheet(of: typ) else {
            return
        }
        guard let sheet = try? String(contentsOf: sheetURL, encoding: .utf8) else {
            throw StyleError.sheetUnreadable(Paths.display(sheetURL))
        }

        let wanted =
            materializedIdentity(choices, fittedToLadder: true)
            + "+sheet-\(TypLibrary.fingerprint(Data(sheet.utf8)))"
        if isMaterialized(dir, as: wanted) { return }

        // The whole base pipeline again, with the sheet slotted in at its own place:
        // after the choices - hides and zoom shifts anchor on the original rule text,
        // so they go first, and a sheet miss on a hidden rule is bookkeeping - and
        // before the translations, which rewrite the label literals the sheet's
        // anchors carry. A zoom-shifted rule differs only in its resolution, which
        // the condition-and-type fallback sees through.
        let build = StyleCatalog.stagingDirectory(for: "recovered")
        defer { FileTools.removeIfPresent(build) }
        try await materializeRules(
            into: build,
            descriptions: choices.descriptions,
            cyrillicLabels: choices.cyrillic,
            log: log,
            runner: runner
        )
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
        try applyUserReassignments(in: build, log: log)
        try install(build, as: dir, marker: wanted)
        log.ok("recovered rule set ready — \(result.applied) reassignment(s) applied")
        if result.hidden > 0 {
            log.append(
                "\(result.hidden) reassignment(s) aimed at rules this build hides"
                    + " — nothing to retarget"
            )
        }
        for miss in result.missed {
            log.warn("recovered reassignment did not match this mkgmap's style — \(miss)")
        }
    }

    /// Prepares whatever the chosen style needs before a build.
    func prepare(
        _ style: MapStyle,
        log: Log,
        runner: ProcessRunner,
        descriptions: BuildRecipe.DescriptionCarrier = .off,
        hidden: Set<String> = [],
        zoom: (plan: ZoomPlan, levels: LevelsProfile) = (.asMeasured, .smooth),
        cyrillicLabels: Bool = false
    ) async throws {
        let choices = StyleChoices(
            descriptions: descriptions,
            hidden: hidden,
            zoom: zoom,
            cyrillic: cyrillicLabels
        )
        // Only a library style: a folder of the user's own that happens to bear the name
        // is theirs, and is never replaced.
        if case .importedTYP = style.origin, style.styleDirectory?.lastPathComponent.hasPrefix("recovered-") == true {
            try await materializeRecoveredStyle(
                style,
                choices: choices,
                log: log,
                runner: runner
            )
        }
        // Written unconditionally, keeping the file in step with the binary's palette
        // without a version marker.
        if let shipped = StyleCatalog.shippedPalette(id: style.id) {
            try holdingStyles {
                try FileTools.write(
                    StyleCatalog.shippedTypText(of: shipped),
                    to: StyleCatalog.shippedTypURL(of: shipped)
                )
            }
        }
        if style.styleDirectory == StyleCatalog.baseStyleDirectory {
            try await materializeBaseStyle(choices, log: log, runner: runner)
        } else if case .customDirectory = style.origin {
            // A folder of the user's own is compiled as it is: said, so a hidden feature
            // that is still drawn does not look like a fault.
            let ignored = Self.choicesNotApplied(choices)
            if !ignored.isEmpty {
                log.warn(
                    "\(style.name) is your own rule folder, compiled as it is — not applied: \(ignored.joined(separator: ", "))"
                )
            }
        }
    }

    /// The build choices that only kmap's own rule set takes.
    static func choicesNotApplied(_ choices: StyleChoices) -> [String] {
        var out: [String] = []
        if !choices.hidden.isEmpty { out.append("hidden features") }
        if choices.zoom.plan.movesAnything { out.append("the zoom plan") }
        if choices.descriptions != .off { out.append("descriptions") }
        if choices.cyrillic { out.append("Russian labels") }
        return out
    }
}
