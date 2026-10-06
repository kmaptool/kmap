import Foundation

/// Drawing the form: the rows, each field's value, and the open list.
extension RecipeForm {
    private static let buttonWidth = 28
    private static let buttonInk = Color.xterm(233)

    func render(into s: Surface, rect whole: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let fields = self.fields
        madePlanCount = ctx.settings.settings.zoomPlans.count
        // A message takes the last row from the form rather than a row of it.
        let rect = message == nil ? whole : Rect(x: whole.x, y: whole.y, w: whole.w, h: max(1, whole.h - 1))
        list.clamp(count: fields.count, visible: fields.count)
        let rows = scrollToSelected(fields, visible: rect.h)
        fieldRows.removeAll(keepingCapacity: true)

        var y = rect.y - scroll
        for (i, field) in fields.enumerated() {
            let selected = i == list.selected

            if field == .build || field == .save {
                y += 1
                if y >= rect.y && y < rect.maxY {
                    drawButton(field, into: s, rect: rect, y: y, selected: selected, theme: theme)
                    fieldRows[field] = y
                }
                y += 1
                continue
            }
            if startsGroup(field) { y += 1 }
            guard y >= rect.y && y < rect.maxY else { y += 1; continue }
            Widgets.field(
                s,
                rect: rect,
                y: y,
                label: field.label,
                value: value(for: field),
                theme: theme,
                labelWidth: Layout.fieldLabel,
                valueStyle: valueStyle(for: field, theme: theme),
                selected: selected
            )
            fieldRows[field] = y
            y += 1
        }
        Widgets.scrollHint(s, rect: rect, offset: scroll, count: rows, visible: rect.h, theme: theme)

        if let message {
            let my = max(rect.y, min(whole.maxY - 1, y + 1))
            s.text(rect.x + 2, my, truncate(message, to: rect.w - 2), Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    /// Rows the fields take, gaps and buttons included, and `scroll` moved so the
    /// selected field is inside `visible` rows: a short terminal used to draw the bottom
    /// of the form, the Build button included, nowhere at all.
    @discardableResult
    private func scrollToSelected(_ fields: [Field], visible: Int) -> Int {
        var rowOf: [Int] = []
        var rows = 0
        for field in fields {
            if field == .build || field == .save || startsGroup(field) { rows += 1 }
            rowOf.append(rows)
            rows += 1
        }
        let selected = rowOf[safe: list.selected] ?? 0
        let shown = max(1, visible)
        if selected < scroll { scroll = selected }
        if selected >= scroll + shown { scroll = selected - shown + 1 }
        scroll = max(0, min(scroll, max(0, rows - shown)))
        return rows
    }

    private func drawButton(_ field: Field, into s: Surface, rect: Rect, y: Int, selected: Bool, theme: Theme) {
        let bg = selected ? theme.accent : theme.raisedBg
        let fg = selected ? Self.buttonInk : theme.text
        let box = Rect(x: rect.x, y: y, w: min(Self.buttonWidth, rect.w), h: 1)
        s.fill(box, Style(fg: fg, bg: bg))
        s.text(box.x + 2, y, field == .build ? t("Build map") : t("Save profile"), Style(fg: fg, bg: bg, bold: true))
        s.textRight(box.maxX - 2, y, Glyph.enter, Style(fg: fg, bg: bg))
    }

    /// Rows that open a group, with a blank line above them.
    private func startsGroup(_ field: Field) -> Bool {
        switch field {
        case .style: return mode == .build
        case .zoomPlan, .routable, .format: return true
        default: return false
        }
    }

    /// Opens a field's list, the way Enter does. For tests, which would otherwise count rows.
    func openPicker(_ field: Field, _ ctx: AppContext) {
        guard let choice = choice(for: field, ctx), choice.listable, choice.options.count > 1 || field == .profile
        else { return }
        picking = (field, choice.options, choice.current)
    }

    /// An overlay: the panel beside the form is painted after the form.
    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        guard let open = picking, let row = fieldRows[open.field] else { return }
        Widgets.optionList(s, within: rect, anchorRow: row, options: open.options, at: open.at, theme: ctx.theme)
    }

    func value(for field: Field) -> String {
        func onOff(_ b: Bool) -> String { b ? t("on") : t("off") }
        switch field {
        case .profile:
            guard let profile = currentProfile else { return "—" }
            return isModified ? profile.name + "  ·  " + t("changed for this map only") : profile.name
        case .style:
            if let missing = missingStyleID { return t("%@ not found — pick a style", missing) }
            return scanningStyles
                ? recipe.style.name + "   " + t("%@ looking for more on your drives", String(Widgets.spinner(frame)))
                : recipe.style.name
        case .contours: return onOff(recipe.contours)
        case .interval: return recipe.contours ? t("%d m", recipe.contourInterval) : "—"
        case .dem: return onOff(recipe.demLayer)
        case .fixSummits:
            guard recipe.demLayer else { return "—" }
            return recipe.fixSummits
                ? t("on") + "  ·  " + t("a summit's cell is lifted to its OSM height")
                : t("off") + "  ·  " + t("the relief is used exactly as measured")
        case .demSource: return recipe.needsElevationData ? recipe.demSources : "—"
        case .zoomPlan:
            let base = RecipeForm.planLabel(recipe.zoomPlan)
            guard recipe.zoomPlan.movesAnything else {
                return base + "  ·  " + (madePlanCount == 0 ? t("⏎ to make another") : t("as it comes"))
            }
            return base
        case .language:
            return (LabelLanguage.all.first { $0.tagList == recipe.nameTagList } ?? .local).name
        case .codePage: return RecipeForm.codePageLabel(recipe.codePage)
        case .familyID: return "\(recipe.familyID)  ·  " + t("tiles from %d", recipe.mapIDBase)
        case .routable: return onOff(recipe.routable)
        case .healRoads:
            return recipe.healRoadEnds
                ? t("on") + "  ·  " + t("joins ends within %d m that block a route", Int(recipe.healRadius))
                : t("off") + "  ·  " + t("the data is used exactly as OSM has it")
        case .index: return onOff(recipe.searchIndex)
        case .houseNumbers: return onOff(recipe.houseNumbers)
        case .sea: return onOff(recipe.generateSea)
        case .theme:
            let hint = RecipeForm.themeHint(recipe.theme)
            return RecipeForm.themeLabel(recipe.theme) + (hint.isEmpty ? "" : "  ·  " + hint)
        case .overlap: return RecipeForm.overlapLabel(recipe.shapeOverlap)
        case .landOverlap: return RecipeForm.overlapLabel(recipe.landOverlap)
        case .descriptions: return recipe.descriptions.label
        case .customPOIs:
            guard recipe.customPOIs else { return t("off") }
            return mode == .build
                ? t("on") + "  ·  " + t("%@.gpi alongside the map", recipe.areaSlug)
                : t("on") + "  ·  " + t("a .gpi alongside the map")
        case .hide:
            guard !recipe.hidden.isEmpty else { return t("nothing — ⏎ to choose") }
            return HideableFeature.all.filter { recipe.hidden.contains($0.id) }.map(\.localizedName).joined(
                separator: ", "
            )
        case .format: return recipe.format.label + "  ·  " + recipe.format.note
        case .splitMode:
            guard recipe.format.writesCardFiles else { return "—" }
            return recipe.splitMode.label
        case .parts:
            guard recipe.format.writesCardFiles, case .count(let n) = recipe.splitMode else { return "—" }
            guard mode == .build else { return tn("%d file(s)", n) }
            let axis = SplitAxis.best(for: recipe.coverage)
            return "\(n) · \(recipe.partNames(count: n, axis: axis).joined(separator: ", "))"
        case .output: return editingOutput ? outputDraft + "▏" : Paths.display(recipe.outputDirectory)
        case .build, .save: return ""
        }
    }

    private func valueStyle(for field: Field, theme: Theme) -> Style? {
        let disabled: Bool
        switch field {
        case .healRoads: disabled = !recipe.routable
        case .interval: disabled = !recipe.contours
        case .demSource: disabled = !recipe.needsElevationData
        case .splitMode: disabled = !recipe.format.writesCardFiles
        case .parts: disabled = !recipe.format.writesCardFiles || recipe.splitMode.fileCount == 0
        default: disabled = false
        }
        if disabled { return Style(fg: theme.faint, bg: theme.appBg) }

        func lit(_ on: Bool) -> Style { Style(fg: on ? theme.ok : theme.faint, bg: theme.appBg) }
        switch field {
        case .profile:
            return Style(fg: isModified ? theme.warn : theme.strong, bg: theme.appBg, bold: !isModified)
        case .contours: return lit(recipe.contours)
        case .dem: return lit(recipe.demLayer)
        case .routable: return lit(recipe.routable)
        case .index: return lit(recipe.searchIndex)
        case .houseNumbers: return lit(recipe.houseNumbers)
        case .sea: return lit(recipe.generateSea)
        case .healRoads: return lit(recipe.healRoadEnds)
        case .fixSummits: return lit(recipe.demLayer && recipe.fixSummits)
        case .customPOIs: return lit(recipe.customPOIs)
        case .descriptions: return lit(recipe.descriptions != .off)
        default: return nil
        }
    }
}
