import Foundation

/// A narrow column of captioned prose that stops at the bottom of its rect.
struct SummaryColumn {
    let s: Surface
    let rect: Rect
    let theme: Theme
    var y: Int

    mutating func caption(_ text: String) {
        guard y < rect.maxY else { return }
        s.sectionRule(
            rect,
            y,
            text,
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 2
    }

    mutating func line(_ text: String, tone: Color? = nil) {
        y = s.paragraph(
            text,
            x: rect.x,
            y: y,
            width: rect.w,
            style: Style(fg: tone ?? theme.text, bg: theme.appBg),
            maxY: rect.maxY
        )
    }

    mutating func gap() { y += 1 }
}
