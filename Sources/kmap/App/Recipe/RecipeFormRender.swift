import Foundation

/// Drawing the form: the rows, each field's current value, and the picker overlay.
extension RecipeForm {
    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let fields = self.fields
        zoomPlanCount = ctx.settings.zoomPlans.count
        list.clamp(count: fields.count, visible: rect.h)

        var y = rect.y
        for (i, field) in fields.enumerated() {
            guard y < rect.maxY else { break }
            let selected = i == list.selected

            if field == .build || field == .save {
                y += 1
                guard y < rect.maxY else { break }
                let bg = selected ? theme.accent : theme.raisedBg
                let fg = selected ? Color.xterm(233) : theme.text
                let box = Rect(x: rect.x, y: y, w: min(28, rect.w), h: 1)
                s.fill(box, Style(fg: fg, bg: bg))
                s.text(box.x + 2, y, field == .build ? t("Build map") : t("Save profile"),
                       Style(fg: fg, bg: bg, bold: true))
                s.textRight(box.maxX - 2, y, Glyph.enter, Style(fg: fg, bg: bg))
                fieldRows[field] = y
                y += 1
                continue
            }

            // Group separators keep the form readable.
            if startsGroup(field) {
                y += 1
                guard y < rect.maxY else { break }
            }

            Widgets.field(s, rect: rect, y: y,
                          label: field.label,
                          value: value(for: field),
                          theme: theme,
                          labelWidth: Layout.fieldLabel,
                          valueStyle: valueStyle(for: field, theme: theme),
                          selected: selected)
            fieldRows[field] = y
            y += 1
        }

        if let message {
            let my = min(rect.maxY - 1, y + 1)
            s.text(rect.x + 2, my, truncate(message, to: rect.w - 2),
                   Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    /// Rows that open a group, with a blank line above them.
    private func startsGroup(_ field: Field) -> Bool {
        switch field {
        // Set apart from the profile row above it, which fills in everything below.
        case .style: return mode == .build
        case .zoomPlan, .routable, .splitMode: return true
        default: return false
        }
    }

    /// Opens a field's list, the way ⏎ does. For tests: reaching a field by keystroke means
    /// counting rows from the top, and that count changes whenever a row is added.
    func openPicker(_ field: Field, _ ctx: AppContext) {
        guard let choice = choice(for: field, ctx), choice.listable,
              choice.options.count > 1 else { return }
        picking = (field, choice.options, choice.current)
    }

    /// The open list, drawn over the form against the field it belongs to.
    ///
    /// An overlay rather than part of `render`: the summary panel beside the form is
    /// painted after it. The widget clamps the box to `rect`.
    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        guard let open = picking, let row = fieldRows[open.field] else { return }
        Widgets.optionList(s, within: rect, anchorRow: row,
                           options: open.options, at: open.at, theme: ctx.theme)
    }

    func value(for field: Field) -> String {
        func onOff(_ b: Bool) -> String { b ? t("on") : t("off") }
        switch field {
        case .profile:
            guard let profile = currentProfile else { return "—" }
            // A form moved away from its profile says so on the row.
            return isModified
                ? profile.name + "  ·  " + t("changed for this map only")
                : profile.name
        case .style:
            // The built-ins are usable straight away; the note is about styles still to
            // be found.
            return scanningStyles
                ? recipe.style.name + "   "
                    + t("%@ looking for more on your drives", String(Widgets.spinner(frame)))
                : recipe.style.name
        case .contours: return onOff(recipe.contours)
        case .interval: return recipe.contours ? t("%d m", recipe.contourInterval) : "—"
        case .dem: return onOff(recipe.demLayer)
        case .demSource: return recipe.needsElevationData ? recipe.demSources : "—"
        case .zoomPlan:
            let base = RecipeForm.planLabel(recipe.zoomPlan)
            guard recipe.zoomPlan.movesAnything else {
                // Distinguishes a plan that moves nothing from having no other plan to pick.
                return base + "  ·  "
                    + (zoomPlanCount < 2 ? t("⏎ to make another") : t("as it comes"))
            }
            return base
        case .language:
            let current = LabelLanguage.all.first { $0.tagList == recipe.nameTagList } ?? .local
            return current.name
        case .codePage:
            return RecipeForm.codePageLabel(recipe.codePage)
        case .familyID:
            return "\(recipe.familyID)  ·  " + t("tiles from %d", recipe.mapIDBase)
        case .routable: return onOff(recipe.routable)
        case .healRoads:
            return recipe.healRoadEnds
                ? t("on") + "  ·  " + t("joins ends within %d m that block a route",
                                        Int(recipe.healRadius))
                : t("off") + "  ·  " + t("the data is used exactly as OSM has it")
        case .index: return onOff(recipe.searchIndex)
        case .houseNumbers: return onOff(recipe.houseNumbers)
        case .sea: return onOff(recipe.generateSea)
        case .theme:
            let hint = RecipeForm.themeHint(recipe.theme)
            return RecipeForm.themeLabel(recipe.theme) + (hint.isEmpty ? "" : "  ·  " + hint)
        case .overlap: return RecipeForm.overlapLabel(recipe.shapeOverlap)
        case .landOverlap:
            return RecipeForm.overlapLabel(recipe.landOverlap)
        case .descriptions: return recipe.descriptions.label
        case .customPOIs:
            guard recipe.customPOIs else { return t("off") }
            // A profile has no map to name the file after.
            return mode == .build
                ? t("on") + "  ·  " + t("%@.gpi alongside the map", recipe.slug)
                : t("on") + "  ·  " + t("a .gpi alongside the map")
        case .hide:
            guard !recipe.hidden.isEmpty else { return t("nothing — ⏎ to choose") }
            let names = HideableFeature.all
                .filter { recipe.hidden.contains($0.id) }
                .map(\.localizedName)
            return names.joined(separator: ", ")
        case .splitMode:
            return recipe.splitMode.label
        case .parts:
            guard case .count(let n) = recipe.splitMode else { return "—" }
            guard mode == .build else { return tn("%d file(s)", n) }
            let axis = SplitAxis.best(for: recipe.coverage)
            return "\(n) · \(recipe.partNames(count: n, axis: axis).joined(separator: ", "))"
        case .output:
            return editingOutput ? outputDraft + "▏" : Paths.display(recipe.outputDirectory)
        case .build, .save: return ""
        }
    }

    private func valueStyle(for field: Field, theme: Theme) -> Style? {
        let disabled: Bool
        switch field {
        case .healRoads: disabled = !recipe.routable
        case .interval: disabled = !recipe.contours
        case .demSource: disabled = !recipe.needsElevationData
        case .parts: disabled = recipe.splitMode.fileCount == 0
        default: disabled = false
        }
        if disabled { return Style(fg: theme.faint, bg: theme.appBg) }

        switch field {
        case .profile:
            return Style(fg: isModified ? theme.warn : theme.strong, bg: theme.appBg,
                         bold: !isModified)
        case .contours, .dem, .routable, .index, .houseNumbers, .sea:
            // Asked of the recipe, not of the drawn value, which is localized.
            let on: Bool
            switch field {
            case .contours: on = recipe.contours
            case .dem: on = recipe.demLayer
            case .routable: on = recipe.routable
            case .index: on = recipe.searchIndex
            case .houseNumbers: on = recipe.houseNumbers
            default: on = recipe.generateSea
            }
            return Style(fg: on ? theme.ok : theme.faint, bg: theme.appBg)
        case .healRoads:
            return Style(fg: recipe.healRoadEnds ? theme.ok : theme.faint, bg: theme.appBg)
        case .customPOIs:
            return Style(fg: recipe.customPOIs ? theme.ok : theme.faint, bg: theme.appBg)
        case .descriptions:
            return Style(fg: recipe.descriptions == .off ? theme.faint : theme.ok,
                         bg: theme.appBg)
        default:
            return nil
        }
    }
}
