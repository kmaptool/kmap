import Foundation

/// Drawing the type editor: the pictures, the field rows, the pickers.
extension TypeEditScreen {
    /// Room for the longest Russian field name, 21 letters, and 2 spaces after it.
    private static let labelWidth = 23
    private static let halfWidth = 18
    /// A colour slot at its narrowest: the pointer, the swatch, a space, `#RRGGBB`, a space.
    private static let leastHalf = 13

    /// Label and colour slot widths for rows `width` wide: the slots narrow first, then the
    /// label, so the colour this screen edits stays whole.
    static func columns(_ width: Int) -> (label: Int, half: Int) {
        // The pointer, and the column between the 2 slots.
        let room = width - 2 - 1
        let half = min(halfWidth, max(leastHalf, (room - labelWidth) / 2))
        return (min(labelWidth, max(8, room - 2 * half)), half)
    }
    /// Rows kept for the scrolling list below the pictures.
    private static let leastListRows = 8
    private static let mostColourRows = 6
    private static let sampleWidth = 12...40
    private static let swatchWidth = 16

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        replacing?.render(into: s, rect: rect, theme: ctx.theme)
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        guard let section else {
            s.text(
                rect.x,
                rect.y,
                t("this TYP has no section for %@", TypeMeaning.hex(code)),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            return
        }
        let fields = self.fields
        // The drawings first, at one row per pixel where there is room.
        let wanted = (section.picture?.height ?? 0) + 3
        var y = drawPictures(
            section,
            into: s,
            rect: rect,
            y: rect.y,
            theme: theme,
            room: max(rect.h / 3, min(wanted, rect.h - Self.leastListRows))
        )

        if !document.isEditable, y < rect.maxY {
            s.text(
                rect.x,
                y,
                t("read-only — press ^F on the style screen for an editable copy"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            y += 2
        }

        let hasPairs = fields.contains {
            if case .colourPair = $0 { return true } else { return false }
        }
        if hasPairs, y < rect.maxY {
            // Over the slots: past the pointer and the label, then 1 apart.
            let columns = Self.columns(rect.w - 1)
            s.text(rect.x + 2 + columns.label, y, t("day"), Style(fg: theme.faint, bg: theme.appBg))
            s.text(
                rect.x + 2 + columns.label + columns.half + 1,
                y,
                t("night"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - 1)
        list.clamp(count: fields.count, visible: listHeight)
        let listTop = y
        // The last column is the scroll hint's only where the list scrolls.
        let rowWidth = fields.count > listHeight ? rect.w - 1 : rect.w
        for offset in 0..<min(listHeight, fields.count - list.offset) {
            let index = list.offset + offset
            guard let field = fields[safe: index] else { break }
            draw(
                field,
                into: s,
                rect: Rect(x: rect.x, y: y, w: rowWidth, h: 1),
                columns: Self.columns(rect.w - 1),
                y: y,
                theme: theme,
                selected: index == list.selected,
                section: section
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: list.offset,
            count: fields.count,
            visible: listHeight,
            theme: theme
        )

        // On the last row, which the list leaves free.
        s.statusLine(message, isError: messageIsError, rect: rect, theme: theme)
        picker?.render(into: s, rect: rect, theme: theme)
    }

    /// Day beside night. A drawing taller than the pane is reduced by a whole factor,
    /// and the size line says by how much.
    private func drawPictures(
        _ section: TypSection,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme,
        room: Int
    ) -> Int {
        guard let day = preview(of: section) else {
            return drawColours(section, into: s, rect: rect, y: y, theme: theme, room: room)
        }
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

        var used = Widgets.picture(
            s,
            x: rect.x,
            y: y + 1,
            day,
            background: theme.appBg,
            maxColumns: columns,
            maxRows: rows
        )
        if let night {
            used = max(
                used,
                Widgets.picture(
                    s,
                    x: nightX,
                    y: y + 1,
                    night,
                    background: theme.appBg,
                    maxColumns: columns,
                    maxRows: rows
                )
            )
        }
        let scale = fit.isReduced ? "  ·  " + t("shown at 1:%d", fit.scale) : ""
        s.text(
            rect.x,
            y + 1 + used,
            "\(day.width)×\(day.height)  " + tn("%d colour(s)", day.declaredColours)
                + scale,
            Style(fg: theme.dim, bg: theme.appBg)
        )
        return y + used + 3
    }

    /// A line at its own thickness with its casing, or a fill as a block of itself.
    private func drawColours(
        _ section: TypSection,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme,
        room: Int
    ) -> Int {
        let slots = section.colourSlots
        guard slots.day.contains(where: { $0.colour != nil }) else { return y }
        let rows = max(1, min(room - 3, Self.mostColourRows))
        let width = min(
            max(Self.sampleWidth.lowerBound, (rect.w - 6) / 2),
            section.kind == .line ? Self.sampleWidth.upperBound : Self.swatchWidth
        )
        let nightX = rect.x + width + 4

        s.text(rect.x, y, t("day"), Style(fg: theme.faint, bg: theme.appBg))
        if !slots.night.isEmpty {
            s.text(nightX, y, t("night"), Style(fg: theme.faint, bg: theme.appBg))
        }

        func draw(_ pair: [TypSection.ColourSlot], at x: Int) {
            guard let fill = pair.first?.colour else { return }
            if section.kind == .line {
                Widgets.lineSample(
                    s,
                    rect: Rect(x: x, y: y + 1, w: width, h: rows),
                    fill: fill,
                    casing: pair.dropFirst().first?.colour,
                    width: section.lineWidth,
                    border: section.borderWidth,
                    background: theme.appBg
                )
                return
            }
            for row in 0..<rows {
                Widgets.swatch(
                    s,
                    x: x,
                    y: y + 1 + row,
                    colour: fill,
                    width: width,
                    theme: theme
                )
            }
        }
        draw(slots.day, at: rect.x)
        draw(slots.night, at: nightX)

        if let lineWidth = section.lineWidth {
            let border = section.borderWidth.map { ", " + t("border %d", $0) } ?? ""
            s.text(
                rect.x,
                y + 1 + rows,
                t("width %d", lineWidth) + border,
                Style(fg: theme.dim, bg: theme.appBg)
            )
        }
        return y + rows + 3
    }

    /// The drawing with the change being typed, before it is saved.
    private func preview(of section: TypSection) -> XpmBlock? {
        guard let picture = section.picture else { return nil }
        guard case .colourPair(_, let day, let night)? = editing else { return picture }
        // A point's night half is its own block, drawn separately.
        guard let slot = onNight ? night : day, slot.tag != "NightXpm" else { return picture }

        let value = draft.trimmingCharacters(in: .whitespaces)
        if meansNone(value) {
            return picture.replacingColour(at: slot.index, with: nil)
        }
        guard Color.hex(value) != nil else { return picture }
        return picture.replacingColour(
            at: slot.index,
            with: "#" + value.replacingOccurrences(of: "#", with: "").uppercased()
        )
    }

    private func draw(
        _ field: Field,
        into s: Surface,
        rect: Rect,
        columns: (label: Int, half: Int),
        y: Int,
        theme: Theme,
        selected: Bool,
        section: TypSection
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        var x = s.text(
            rect.x,
            y,
            selected ? "\(Glyph.arrowRight) " : "  ",
            Style(fg: theme.accent, bg: bg)
        )

        func label(_ text: String) {
            x = s.text(
                x,
                y,
                truncate(text, to: columns.label - 1).padding(toLength: columns.label, withPad: " ", startingAt: 0),
                Style(fg: theme.dim, bg: bg)
            )
        }

        /// The row's value, cut short of the key hint at the right edge, which goes where
        /// there is no room for both.
        func value(_ text: String, _ style: Style, hint: String) {
            let hint = "⏎ " + hint
            let room = rect.maxX - x - hint.count - 2
            s.text(x, y, truncate(text, to: max(0, room > 8 ? room : rect.maxX - x)), style)
            if room > 8 { s.textRight(rect.maxX, y, hint, Style(fg: theme.faint, bg: bg)) }
        }

        switch field {
        case .picture:
            label(t("Drawing"))
            let description =
                section.picture.map {
                    "\($0.width)×\($0.height), " + tn("%d colour(s)", $0.declaredColours)
                } ?? t("solid colours, no pattern")
            value(description, Style(fg: theme.text, bg: bg), hint: t("borrow one"))

        case .drawPicture:
            label(t("Draw"))
            value(
                section.picture == nil
                    ? t("start a pattern from this type's own colour")
                    : t("pixel by pixel, with the pointer"),
                Style(fg: theme.text, bg: bg),
                hint: t("open the editor")
            )

        case .addNight:
            label(t("Night version"))
            value(t("none — the day drawing is used after dark"), Style(fg: theme.warn, bg: bg), hint: t("start one"))

        case .colourPair(let role, let day, let night):
            label(role)
            let editingThis = selected && editing != nil
            x = half(
                s,
                x: x,
                y: y,
                maxX: rect.maxX,
                width: columns.half,
                slot: day,
                focused: selected && !onNight,
                draft: editingThis && !onNight ? draft : nil,
                theme: theme,
                bg: bg
            )
            x += 1
            half(
                s,
                x: x,
                y: y,
                maxX: rect.maxX,
                width: columns.half,
                slot: night,
                focused: selected && onNight,
                draft: editingThis && onNight ? draft : nil,
                theme: theme,
                bg: bg
            )

        case .fontStyle:
            label(t("Label size"))
            let current = section.fontStyle ?? ""
            value(
                current.isEmpty ? t("whatever the device uses") : current,
                Style(fg: current.isEmpty ? theme.faint : theme.text, bg: bg),
                hint: t("next")
            )

        case .labelColour:
            label(t("Label colour"))
            let editingThis = selected && editing != nil
            let day = section.dayLabelColour.map {
                TypSection.ColourSlot(role: "day", tag: "DayCustomColor", index: 0, colour: $0)
            }
            let night = section.nightLabelColour.map {
                TypSection.ColourSlot(
                    role: "night",
                    tag: "NightCustomColor",
                    index: 0,
                    colour: $0
                )
            }
            x = half(
                s,
                x: x,
                y: y,
                maxX: rect.maxX,
                width: columns.half,
                slot: day
                    ?? TypSection.ColourSlot(
                        role: "day",
                        tag: "DayCustomColor",
                        index: 0,
                        colour: nil
                    ),
                focused: selected && !onNight,
                draft: editingThis && !onNight ? draft : nil,
                theme: theme,
                bg: bg
            )
            x += 1
            half(
                s,
                x: x,
                y: y,
                maxX: rect.maxX,
                width: columns.half,
                slot: night
                    ?? TypSection.ColourSlot(
                        role: "night",
                        tag: "NightCustomColor",
                        index: 0,
                        colour: nil
                    ),
                focused: selected && onNight,
                draft: editingThis && onNight ? draft : nil,
                theme: theme,
                bg: bg
            )

        case .label(let language, let name):
            label(name)
            let editingThis = selected && editing != nil
            let current = section.label(language: language)
            let end = s.text(
                x,
                y,
                truncate(editingThis ? draft : (current ?? "—"), to: max(0, rect.maxX - x - 1)),
                Style(fg: theme.strong, bg: bg, bold: editingThis)
            )
            if editingThis { s.put(end, y, "▏", Style(fg: theme.accent, bg: bg)) }
        }
    }

    /// One half of a colour pair: a swatch, then the value beside it, cut at `maxX`. A slot
    /// the file says nothing about is a dash.
    @discardableResult
    private func half(
        _ s: Surface,
        x: Int,
        y: Int,
        maxX: Int,
        width: Int,
        slot: TypSection.ColourSlot?,
        focused: Bool,
        draft: String?,
        theme: Theme,
        bg: Color
    ) -> Int {
        guard let slot else {
            s.text(
                x + 1,
                y,
                truncate(focused ? "— ⏎ " + t("add one") : "—", to: max(0, maxX - x - 1)),
                Style(fg: focused ? theme.accent : theme.faint, bg: bg)
            )
            return x + width
        }
        var cursor = s.text(
            x,
            y,
            focused ? "▸" : " ",
            Style(fg: theme.accent, bg: bg, bold: focused)
        )
        let shown = draft ?? slot.colour
        cursor = Widgets.swatch(s, x: cursor, y: y, colour: shown, width: 3, theme: theme)
        cursor += 1
        let end = s.text(
            cursor,
            y,
            truncate(shown ?? t("none"), to: max(0, maxX - cursor - (draft == nil ? 0 : 1))),
            Style(
                fg: shown == nil ? theme.faint : theme.strong,
                bg: bg,
                bold: draft != nil
            )
        )
        if draft != nil { s.put(end, y, "▏", Style(fg: theme.accent, bg: bg)) }
        return x + width
    }
}
