import Foundation

/// The build form: the rows, their values, what ←→ and ⏎ do to them, and how it is drawn.
///
/// Shared by the map build screen and the profile editor; `Mode` selects which rows are
/// offered and what the button at the end commits.
@MainActor
final class RecipeForm {

    /// Which screen is showing the form.
    enum Mode {
        /// A map about to be built: the profile row at the top, the family id, the folder,
        /// and Build at the end.
        case build
        /// A profile being edited: without those three rows, and Save at the end.
        case profile
    }

    /// What the screen has to act on itself. Everything else the form has already done.
    enum Outcome {
        case none
        /// A screen to push — the style picker, the list of hideable features.
        case route(Route)
        /// The button at the end was pressed: Build, or Save.
        case commit
        /// A different profile was chosen at the top; the form has already applied it.
        case profileChosen(String)
    }

    enum Field: Int, CaseIterable {
        case profile
        case style, contours, interval, dem, fixSummits, demSource, zoomPlan, language, codePage,
             familyID
        case routable, healRoads, index, houseNumbers, sea, descriptions
        case customPOIs, hide
        case splitMode, parts, output
        case theme, overlap, landOverlap
        case build, save

        var label: String {
            switch self {
            case .profile: return t("Profile")
            case .style: return t("Style")
            case .contours: return t("Contour lines")
            case .interval: return t("Interval")
            case .dem: return t("DEM layer")
            case .fixSummits: return t("Fix summits")
            case .demSource: return t("Elevation data")
            // The ladder and its population in one row: a plan already names its ladder.
            case .zoomPlan: return t("Zoom plan")
            // The language of the names in the map, not of the interface: a build choice
            // that reaches the tiles.
            case .language: return t("Labels")
            case .codePage: return t("Code page")
            case .familyID: return t("Family id")
            case .routable: return t("Routable")
            case .healRoads: return t("Repair road ends")
            case .index: return t("Search index")
            case .houseNumbers: return t("House numbers")
            case .sea: return t("Coastlines")
            case .descriptions: return t("Descriptions")
            case .customPOIs: return t("Custom POI file")
            case .hide: return t("Hide on map")
            case .splitMode: return t("Output files")
            case .parts: return t("How many")
            case .output: return t("Folder")
            case .theme: return t("Theme")
            case .overlap: return t("Tile overlap")
            case .landOverlap: return t("Land overlap")
            case .build, .save: return ""
            }
        }
    }

    let mode: Mode
    /// Whether the compiler in this toolchain can draw past a tile frame. Probed once, when
    /// the screen makes the form.
    let hasSeamPatch: Bool
    var recipe: BuildRecipe
    /// What the region asks for, used wherever a profile leaves the code page open. Zero in
    /// profile mode, where there is no region to ask.
    let regionCodePage: Int

    /// Offered at the top in build mode. Already in the order they are shown in.
    var profiles: [BuildProfile] = []
    var currentProfileID = ""

    // Written by the render extension too (clamping), so not private(set).
    var list = ListState()
    private(set) var styleChoices: [MapStyle] = []
    private(set) var scanningStyles = false
    /// Style asked for, kept while the disk scan is still finding it.
    private(set) var wantedStyleID: String?
    /// How many zoom plans there are, refreshed as the form draws. Read in `value(for:)`,
    /// which has no context to ask the store with.
    var zoomPlanCount = 1

    /// A plan labelled with the ladder it is built on.
    static func planLabel(_ plan: ZoomPlan) -> String {
        let ladder = LevelsProfile.all.first { $0.id == plan.levelsID }?.name ?? ""
        return ladder.isEmpty ? t(plan.name) : t(plan.name) + "  ·  " + ladder
    }
    var message: String?
    var editingOutput = false
    var outputDraft = ""
    var frame = 0
    /// The list a field opens on ⏎: the options and where the cursor sits. Picking applies
    /// through the same `Choice` that ←→ steps along.
    var picking: (field: Field, options: [String], at: Int)?
    /// Where each field was last drawn, so its list opens against it.
    var fieldRows: [Field: Int] = [:]

    let intervals = [5, 10, 20, 25, 50]
    private let codePages = [CodePage.westernEuropean, CodePage.cyrillic,
                             CodePage.centralEuropean, CodePage.utf8]

    init(mode: Mode, recipe: BuildRecipe, regionCodePage: Int = 0, askedStyleID: String? = nil,
         hasSeamPatch: Bool = false) {
        self.mode = mode
        self.hasSeamPatch = hasSeamPatch
        self.recipe = recipe
        self.regionCodePage = regionCodePage
        self.wantedStyleID = askedStyleID
    }

    /// The rows on offer, in the order they are drawn.
    var fields: [Field] {
        switch mode {
        case .build:
            return Field.allCases.filter { $0 != .save && shows($0) }
        case .profile:
            // No region in profile mode: no family id and no folder, which belong to a map.
            return Field.allCases.filter {
                $0 != .profile && $0 != .familyID && $0 != .output && $0 != .build
                    && shows($0)
            }
        }
    }

    /// Whether a field is offered at all.
    ///
    /// The overlap rows need the seam patch: a stock mkgmap cannot draw past a tile frame.
    /// A recipe keeps its overlap numbers while the rows are hidden.
    private func shows(_ field: Field) -> Bool {
        switch field {
        case .overlap, .landOverlap: return hasSeamPatch
        default: return true
        }
    }

    var isPicking: Bool { picking != nil }
    var isEditingText: Bool { editingOutput }

    /// The keys this form offers, for the screen that hosts it to put in its page.
    var keys: [Hint] {
        if editingOutput {
            var hints = [Hint(key: Glyph.enter, label: t("accept"))]
            if FilePicker.isAvailable { hints.append(Hint(key: "^O", label: t("browse"))) }
            hints.append(Hint(key: "esc", label: t("cancel")))
            return hints
        }
        if picking != nil {
            return [Hint(key: "↑↓", label: t("choose")),
                    Hint(key: Glyph.enter, label: t("take it")),
                    Hint(key: "esc", label: t("leave as is"))]
        }
        return [Hint(key: "↑↓", label: t("field")),
                Hint(key: "←→", label: t("change")),
                Hint(key: Glyph.enter, label: mode == .build ? t("open · build") : t("open · save"))]
    }

    // MARK: The profile at the top

    /// The row the cursor is on, so the panel beside the form can say what it is for.
    var selectedField: Field? { fields[safe: list.selected] }

    var currentProfile: BuildProfile? {
        profiles.first { $0.id == currentProfileID } ?? profiles.first
    }

    /// Whether the form has been moved away from the profile it was filled in from. An
    /// edited form builds this map differently and leaves the profile unchanged.
    var isModified: Bool {
        guard let profile = currentProfile else { return false }
        return !recipe.matches(profile.choices,
                               regionCodePage: regionCodePage,
                               askedStyleID: wantedStyleID ?? recipe.style.id)
    }

    /// Fills the whole form in from a profile, leaving the map's own things alone.
    func use(_ profile: BuildProfile, _ ctx: AppContext) {
        currentProfileID = profile.id
        wantedStyleID = profile.choices.styleID
        refreshStyles(ctx)
        recipe.apply(profile.choices,
                     style: styleChoices.first { $0.id == profile.choices.styleID },
                     regionCodePage: regionCodePage)
        // Follows the profile, not the choices: editing a field afterwards leaves the name.
        recipe.profileName = profile.name
        message = nil
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Outcome {
        if editingOutput { return handleOutput(key) }
        if picking != nil { return handlePicking(key, ctx) }

        let fields = self.fields
        switch key {
        case .up, .char("k"): list.move(-1, count: fields.count)
        case .down, .char("j"), .tab: list.move(1, count: fields.count)
        case .left, .char("h"): return adjust(fields[safe: list.selected], by: -1, ctx)
        case .right, .char("l"): return adjust(fields[safe: list.selected], by: 1, ctx)
        case .char(" "): return adjust(fields[safe: list.selected], by: 1, ctx)
        case .enter:
            guard let field = fields[safe: list.selected] else { return .none }
            return open(field, ctx)
        default: break
        }
        return .none
    }

    private func handleOutput(_ key: KeyEvent) -> Outcome {
        switch key {
        case .ctrl("o"):
            if let chosen = FilePicker.choose(.directory,
                                              startingAt: Paths.expand(outputDraft),
                                              prompt: t("Output folder")) {
                outputDraft = chosen.path
            }
        case .enter, .esc:
            if key == .enter, !outputDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                recipe.outputDirectory = Paths.expand(outputDraft)
            }
            editingOutput = false
        case .backspace: if !outputDraft.isEmpty { outputDraft.removeLast() }
        case .char(let c): outputDraft.append(c)
        case .paste(let text): outputDraft += text.replacingOccurrences(of: "\n", with: "")
        default: break
        }
        return .none
    }

    private func handlePicking(_ key: KeyEvent, _ ctx: AppContext) -> Outcome {
        guard var open = picking else { return .none }
        switch key {
        case .up, .char("k"):
            open.at = (open.at - 1 + open.options.count) % open.options.count
            picking = open
        case .down, .char("j"), .tab:
            open.at = (open.at + 1) % open.options.count
            picking = open
        case .enter, .char(" "):
            picking = nil
            if let choice = choice(for: open.field, ctx), open.at != choice.current,
               open.at < choice.options.count {
                return choice.choose(open.at)
            }
        case .esc, .left, .char("h"), .ctrl("c"):
            picking = nil
        default: break
        }
        return .none
    }

    /// What ⏎ does to a row: start it, open its own screen, or open the list it cycles.
    private func open(_ field: Field, _ ctx: AppContext) -> Outcome {
        switch field {
        case .build, .save:
            return .commit
        case .output:
            editingOutput = true
            outputDraft = recipe.outputDirectory.path
            return .none
        case .hide:
            return .route(.push(HideScreen(hidden: recipe.hidden) { [weak self] picked in
                // Reaches this build only; the profile it came from stays as it was.
                self?.recipe.hidden = picked
            }))
        case .style:
            // A dedicated screen: TYPs found inside maps make the list too long to cycle.
            refreshStyles(ctx)
            return .route(.push(
                StylePickerScreen(styles: styleChoices, current: recipe.style) {
                    [weak self] picked in
                    self?.recipe.style = picked
                    self?.wantedStyleID = picked.id
                }))
        case .zoomPlan where ctx.settings.zoomPlans.count < 2:
            // Nothing to cycle: only the plan that ships. ⏎ opens where a second is made.
            return .route(.push(ZoomPlansScreen()))

        default:
            // Everything else cycles with ←→, and ⏎ opens what it is cycling through.
            if let choice = choice(for: field, ctx), choice.listable, choice.options.count > 1 {
                picking = (field, choice.options, choice.current)
                return .none
            }
            return adjust(field, by: 1, ctx)
        }
    }

    private func adjust(_ field: Field?, by delta: Int, _ ctx: AppContext) -> Outcome {
        guard let field else { return .none }
        message = nil

        switch field {
        case .style:
            // Not a `Choice`: styles arrive as the disk scan finds them, and the one asked
            // for is held apart until it does.
            refreshStyles(ctx)
            guard !styleChoices.isEmpty else { return .none }
            let at = styleChoices.firstIndex { $0.id == recipe.style.id } ?? 0
            let next = ((at + delta) % styleChoices.count + styleChoices.count)
                % styleChoices.count
            recipe.style = styleChoices[next]
            wantedStyleID = recipe.style.id
            return .none
        case .familyID:
            recipe.familyID = max(1, min(65535, recipe.familyID + delta))
            return .none
        case .hide, .output, .build, .save:
            // These open their own screen or editor rather than cycling a value.
            return .none
        default:
            guard let choice = choice(for: field, ctx), !choice.options.isEmpty else {
                return .none
            }
            let count = choice.options.count
            return choice.choose(((choice.current + delta) % count + count) % count)
        }
    }

    /// The elevation sources on offer. Copernicus and Viewfinder are fetched directly;
    /// SRTM and ALOS need pyhgtmap and a stored login, and appear only when both are there.
    func sourceChoices(_ ctx: AppContext) -> [String] {
        var choices = [BuildRecipe.recommendedDEMSources, "copernicus1", "copernicus3",
                       "view1,view3", "view1", "view3"]
        // A source with no usable login downloads nothing and fails late in the build.
        if ctx.toolchain.findPyhgtmap() != nil {
            if ElevationLogins.usable(.srtm) { choices.append("srtm1,view3") }
            if ElevationLogins.usable(.alos) { choices.append("alos1,view3") }
        }
        // The recipe's current source stays on the list, so a cleared login cannot silently
        // change it.
        if !choices.contains(recipe.demSources) { choices.append(recipe.demSources) }
        return choices
    }

    /// The code pages on offer. Profile mode adds 0, meaning the region decides; a map
    /// being built already knows its region.
    var codePageChoices: [Int] {
        mode == .profile ? [0] + codePages : codePages
    }

    /// A code page as the field and its list both say it.
    static func codePageLabel(_ page: Int) -> String {
        page == 0
            ? t("by region") + "  ·  " + t("1251 for Cyrillic names, 1252 for the rest")
            : "\(page)  ·  " + alphabet(page)
    }

    /// Which alphabet a code page carries, in words.
    static func alphabet(_ page: Int) -> String {
        switch page {
        case 1251: return t("Cyrillic")
        case 1250: return t("central Europe")
        case 65001: return t("Unicode")
        default: return t("western Europe")
        }
    }

    /// Picks up whatever the catalogue can offer now. While the disk scan runs that is only
    /// the built-ins, which is enough to show the screen and to build with.
    private func refreshStyles(_ ctx: AppContext) {
        guard styleChoices.isEmpty || scanningStyles else { return }
        // A profile may name a style the scan has not found yet; the wanted id is held
        // apart so the placeholder shown meanwhile does not become the answer.
        if wantedStyleID == nil { wantedStyleID = ctx.settings.settings.defaultStyleID }

        let (list, scanning) = ctx.styles.styles()
        scanningStyles = scanning
        guard !list.isEmpty else { return }
        styleChoices = list

        if let preferred = list.first(where: { $0.id == wantedStyleID }) {
            recipe.style = preferred
        } else if !list.contains(where: { $0.id == recipe.style.id }) {
            recipe.style = list[0]
        }
    }

    func tick(_ ctx: AppContext) {
        frame &+= 1
        refreshStyles(ctx)
    }
}
