import Foundation

/// Drawing the type editor: the field rows, the preview, the pickers.
extension TypeEditScreen {
    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        guard let section else {
            s.text(rect.x, rect.y,
                   t("this TYP has no section for %@", TypeMeaning.hex(code)),
                   Style(fg: theme.warn, bg: theme.appBg))
            return
        }
        var y = rect.y
        let fields = self.fields

        // The drawings first, day beside night, at one terminal row per pixel where there
        // is room; at least eight rows are kept for the scrolling list below.
        let wanted = (section.picture?.height ?? 0) + 3
        y = drawPictures(section, into: s, rect: rect, y: y, theme: theme,
                         room: max(rect.h / 3, min(wanted, rect.h - 8)))

        if !document.isEditable, y < rect.maxY {
            s.text(rect.x, y,
                   t("read-only — press ^F on the style screen for an editable copy"),
                   Style(fg: theme.warn, bg: theme.appBg))
            y += 2
        }

        // Column headings, so the two blocks on every row below have names.
        let hasPairs = fields.contains {
            if case .colourPair = $0 { return true } else { return false }
        }
        if hasPairs, y < rect.maxY {
            s.text(rect.x + 20, y, t("day"), Style(fg: theme.faint, bg: theme.appBg))
            s.text(rect.x + 38, y, t("night"), Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - 1)
        list.clamp(count: fields.count, visible: listHeight)
        let listTop = y
        for offset in 0..<min(listHeight, fields.count - list.offset) {
            let index = list.offset + offset
            guard let field = fields[safe: index] else { break }
            draw(field, into: s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                 theme: theme, selected: index == list.selected, section: section)
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: fields.count,
                           visible: listHeight, theme: theme)

        if let message, rect.maxY - 1 > y {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }
        // Over everything else.
        picker?.render(into: s, rect: rect, theme: theme)
    }

    /// The day drawing and, where there is one, the night drawing beside it. A pixel takes
    /// a whole terminal row; a drawing taller than the pane is reduced by a whole factor,
    /// and the size line says by how much.
    private func drawPictures(_ section: TypSection, into s: Surface, rect: Rect, y: Int,
                              theme: Theme, room: Int) -> Int {
        guard let day = preview(of: section) else {
            return drawColours(section, into: s, rect: rect, y: y, theme: theme, room: room)
        }
        // A pattern keeps its night in a second pair of colours rather than a second block,
        // so this is not just the point's `NightXpm`.
        let night = section.nightPicture
        let rows = room - 3
        guard rows >= 1 else { return y }
        let columns = night == nil ? rect.w : max(2, (rect.w - 4) / 2)
        let fit = Widgets.pictureFit(day, maxColumns: columns, maxRows: rows)
        guard fit.rows > 0 else { return y }

        s.text(rect.x, y, t("day"), Style(fg: theme.faint, bg: theme.appBg))
        let nightX = rect.x + fit.columns + 4
        if night != nil {
            s.text(nightX, y, t("night"), Style(fg: theme.faint, bg: theme.appBg))
        }

        var used = Widgets.picture(s, x: rect.x, y: y + 1, day, background: theme.appBg,
                                   maxColumns: columns, maxRows: rows)
        if let night {
            used = max(used, Widgets.picture(s, x: nightX, y: y + 1, night,
                                             background: theme.appBg,
                                             maxColumns: columns, maxRows: rows))
        }
        let scale = fit.isReduced ? "  ·  " + t("shown at 1:%d", fit.scale) : ""
        s.text(rect.x, y + 1 + used,
               "\(day.width)×\(day.height)  " + tn("%d colour(s)", day.declaredColours)
                   + scale,
               Style(fg: theme.dim, bg: theme.appBg))
        return y + used + 3
    }

    /// What the device draws where there is no picture: a line at its own thickness with
    /// its casing, day and night, or a fill as a block of itself.
    private func drawColours(_ section: TypSection, into s: Surface, rect: Rect, y: Int,
                             theme: Theme, room: Int) -> Int {
        let slots = section.colourSlots
        guard slots.day.contains(where: { $0.colour != nil }) else { return y }
        let rows = max(1, min(room - 3, 6))
        let width = min(max(12, (rect.w - 6) / 2), section.kind == .line ? 40 : 16)
        let nightX = rect.x + width + 4

        s.text(rect.x, y, t("day"), Style(fg: theme.faint, bg: theme.appBg))
        if !slots.night.isEmpty {
            s.text(nightX, y, t("night"), Style(fg: theme.faint, bg: theme.appBg))
        }

        func draw(_ pair: [TypSection.ColourSlot], at x: Int) {
            guard let fill = pair.first?.colour else { return }
            if section.kind == .line {
                Widgets.lineSample(s, rect: Rect(x: x, y: y + 1, w: width, h: rows),
                                   fill: fill, casing: pair.dropFirst().first?.colour,
                                   width: section.lineWidth, border: section.borderWidth,
                                   background: theme.appBg)
                return
            }
            for row in 0..<rows {
                Widgets.swatch(s, x: x, y: y + 1 + row, colour: fill, width: width,
                               theme: theme)
            }
        }
        draw(slots.day, at: rect.x)
        draw(slots.night, at: nightX)

        if let lineWidth = section.lineWidth {
            let border = section.borderWidth.map { ", " + t("border %d", $0) } ?? ""
            s.text(rect.x, y + 1 + rows, t("width %d", lineWidth) + border,
                   Style(fg: theme.dim, bg: theme.appBg))
        }
        return y + rows + 3
    }

    /// The drawing as it would look with the change being typed, before it is saved.
    private func preview(of section: TypSection) -> XpmBlock? {
        guard let picture = section.picture else { return nil }
        guard case .colourPair(_, let day, let night)? = editing else { return picture }
        // The night half of a point lives in its own block, which is drawn separately.
        guard let slot = onNight ? night : day, slot.tag != "NightXpm" else { return picture }

        let value = draft.trimmingCharacters(in: .whitespaces)
        if meansNone(value) {
            return picture.replacingColour(at: slot.index, with: nil)
        }
        guard Color.hex(value) != nil else { return picture }
        return picture.replacingColour(
            at: slot.index,
            with: "#" + value.replacingOccurrences(of: "#", with: "").uppercased())
    }

    private func draw(_ field: Field, into s: Surface, rect: Rect, y: Int, theme: Theme,
                      selected: Bool, section: TypSection) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        var x = s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ",
                       Style(fg: theme.accent, bg: bg))

        func label(_ text: String) {
            x = s.text(x, y, text.padding(toLength: 18, withPad: " ", startingAt: 0),
                       Style(fg: theme.dim, bg: bg))
        }

        switch field {
        case .picture:
            label(t("Drawing"))
            let description = section.picture.map {
                "\($0.width)×\($0.height), " + tn("%d colour(s)", $0.declaredColours)
            } ?? t("solid colours, no pattern")
            s.text(x, y, description, Style(fg: theme.text, bg: bg))
            s.textRight(rect.maxX, y, "⏎ " + t("borrow one"), Style(fg: theme.faint, bg: bg))

        case .drawPicture:
            label(t("Draw"))
            s.text(x, y, section.picture == nil
                    ? t("start a pattern from this type's own colour")
                    : t("pixel by pixel, with the pointer"),
                   Style(fg: theme.text, bg: bg))
            s.textRight(rect.maxX, y, "⏎ " + t("open the editor"),
                        Style(fg: theme.faint, bg: bg))

        case .addNight:
            label(t("Night version"))
            s.text(x, y, t("none — the day drawing is used after dark"),
                   Style(fg: theme.warn, bg: bg))
            s.textRight(rect.maxX, y, "⏎ " + t("start one"), Style(fg: theme.faint, bg: bg))

        case .colourPair(let role, let day, let night):
            label(role)
            let editingThis = selected && editing != nil
            x = half(s, x: x, y: y, slot: day, focused: selected && !onNight,
                     draft: editingThis && !onNight ? draft : nil, theme: theme, bg: bg)
            x += 1
            half(s, x: x, y: y, slot: night, focused: selected && onNight,
                 draft: editingThis && onNight ? draft : nil, theme: theme, bg: bg)

        case .fontStyle:
            label(t("Label size"))
            let current = section.fontStyle ?? ""
            s.text(x, y, current.isEmpty ? t("whatever the device uses") : current,
                   Style(fg: current.isEmpty ? theme.faint : theme.text, bg: bg))
            s.textRight(rect.maxX, y, "⏎ " + t("next"), Style(fg: theme.faint, bg: bg))

        case .labelColour:
            label(t("Label colour"))
            let editingThis = selected && editing != nil
            let day = section.dayLabelColour.map {
                TypSection.ColourSlot(role: "day", tag: "DayCustomColor", index: 0, colour: $0)
            }
            let night = section.nightLabelColour.map {
                TypSection.ColourSlot(role: "night", tag: "NightCustomColor", index: 0,
                                      colour: $0)
            }
            x = half(s, x: x, y: y,
                     slot: day ?? TypSection.ColourSlot(role: "day", tag: "DayCustomColor",
                                                        index: 0, colour: nil),
                     focused: selected && !onNight,
                     draft: editingThis && !onNight ? draft : nil, theme: theme, bg: bg)
            x += 1
            half(s, x: x, y: y,
                 slot: night ?? TypSection.ColourSlot(role: "night", tag: "NightCustomColor",
                                                      index: 0, colour: nil),
                 focused: selected && onNight,
                 draft: editingThis && onNight ? draft : nil, theme: theme, bg: bg)

        case .label(let language, let name):
            label(name)
            let editingThis = selected && editing != nil
            let current = section.label(language: language)
            let end = s.text(x, y, editingThis ? draft : (current ?? "—"),
                             Style(fg: theme.strong, bg: bg, bold: editingThis))
            if editingThis { s.put(end, y, "▏", Style(fg: theme.accent, bg: bg)) }
        }
    }

    /// One half of a colour pair: a block, then the value spelt out beside it. A slot the
    /// file says nothing about is left as a dash.
    @discardableResult
    private func half(_ s: Surface, x: Int, y: Int, slot: TypSection.ColourSlot?,
                      focused: Bool, draft: String?, theme: Theme, bg: Color) -> Int {
        let width = 18
        guard let slot else {
            s.text(x + 1, y, focused ? "— ⏎ " + t("add one") : "—",
                   Style(fg: focused ? theme.accent : theme.faint, bg: bg))
            return x + width
        }
        var cursor = s.text(x, y, focused ? "▸" : " ",
                            Style(fg: theme.accent, bg: bg, bold: focused))
        let shown = draft ?? slot.colour
        cursor = Widgets.swatch(s, x: cursor, y: y, colour: shown, width: 3, theme: theme)
        cursor += 1
        let end = s.text(cursor, y, shown ?? t("none"),
                         Style(fg: shown == nil ? theme.faint : theme.strong, bg: bg,
                               bold: draft != nil))
        if draft != nil { s.put(end, y, "▏", Style(fg: theme.accent, bg: bg)) }
        return x + width
    }
}
