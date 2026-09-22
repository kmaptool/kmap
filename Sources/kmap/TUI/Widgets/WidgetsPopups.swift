import Foundation

/// What is drawn over a screen: a message box, and the list a field drops down.
extension Widgets {
    /// The widest a notice is drawn, and the margin it keeps from the edges.
    private static let noticeWidthLimit = 72
    private static let noticeMargin = 8
    /// Options shown at a time in a dropdown, scrolled to keep the selection in view.
    private static let optionsVisible = 10
    private static let optionListNarrowest = 24
    /// Where a dropdown starts unless the field says otherwise: past its label column.
    static let optionListIndent = 18

    /// A centred message box drawn over the screen.
    static func notice(
        _ s: Surface,
        rect: Rect,
        title: String,
        message: String,
        theme: Theme,
        tone: Color? = nil
    ) {
        let width = min(rect.w - noticeMargin, noticeWidthLimit)
        let body = wrapText(message, width: width - 4)
        let height = body.count + 4
        let box = Rect(
            x: rect.x + (rect.w - width) / 2,
            y: rect.y + max(0, (rect.h - height) / 2),
            w: width,
            h: height
        )
        s.fill(box, Style(fg: theme.text, bg: theme.panelBg))
        s.box(
            box,
            Style(fg: tone ?? theme.rule, bg: theme.panelBg),
            title: title,
            titleStyle: Style(fg: tone ?? theme.accent, bg: theme.panelBg, bold: true)
        )
        for (i, line) in body.enumerated() {
            s.text(box.x + 2, box.y + 2 + i, line, Style(fg: theme.text, bg: theme.panelBg))
        }
    }

    /// The dropdown a field opens, anchored to `row`: below it where there is room and
    /// above it otherwise.
    static func optionList(
        _ s: Surface,
        within form: Rect,
        anchorRow row: Int,
        options: [String],
        at index: Int,
        theme: Theme,
        indent: Int = optionListIndent
    ) {
        guard !options.isEmpty, form.w > 8 else { return }
        let width = min(form.w - 4, max(optionListNarrowest, (options.map(\.count).max() ?? 20) + 6))
        let visible = min(optionsVisible, options.count)
        let first = max(0, min(options.count - visible, index - visible / 2))
        let height = visible + 2
        let top = row + 1 + height <= form.maxY ? row + 1 : max(form.y, row - height)
        let box = Rect(
            x: form.x + min(indent, max(0, form.w - width)),
            y: top,
            w: width,
            h: height
        )

        s.fill(box, Style(fg: theme.text, bg: theme.raisedBg))
        s.box(box, Style(fg: theme.accent, bg: theme.raisedBg))
        for i in 0..<visible {
            let at = first + i
            guard let option = options[safe: at] else { break }
            let picked = at == index
            let style = Style(
                fg: picked ? theme.strong : theme.text,
                bg: picked ? theme.selectionBg : theme.raisedBg,
                bold: picked
            )
            s.fill(Rect(x: box.x + 1, y: box.y + 1 + i, w: box.w - 2, h: 1), style)
            s.text(
                box.x + 2,
                box.y + 1 + i,
                picked ? "\(Glyph.check) " : "  ",
                Style(fg: theme.picked, bg: style.bg)
            )
            s.text(box.x + 4, box.y + 1 + i, truncate(option, to: box.w - 5), style)
        }
    }
}
