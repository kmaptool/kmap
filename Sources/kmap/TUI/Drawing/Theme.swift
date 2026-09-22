import Foundation

/// The interface palette: greyscale for structure, colour for state and selection.
struct Theme {
    let appBg = Color.xterm(233)
    let panelBg = Color.xterm(234)
    let raisedBg = Color.xterm(236)

    let text = Color.xterm(252)
    let strong = Color.xterm(255)
    let dim = Color.xterm(245)
    let faint = Color.xterm(240)
    let rule = Color.xterm(237)

    /// Steel blue.
    let accent = Color.xterm(74)
    let accentDim = Color.xterm(67)
    /// Muted green, and a brighter one for what is picked.
    let ok = Color.xterm(108)
    let picked = Color.xterm(114)
    /// Khaki.
    let warn = Color.xterm(179)
    /// Muted red.
    let danger = Color.xterm(167)

    let headerBg = Color.xterm(236)
    let headerFg = Color.xterm(253)
    let footerBg = Color.xterm(235)
    let footerFg = Color.xterm(246)
    let selectionBg = Color.xterm(238)
    let selectionFg = Color.xterm(255)

    var base: Style { Style(fg: text, bg: appBg) }
    var panel: Style { Style(fg: text, bg: panelBg) }
    var border: Style { Style(fg: rule, bg: appBg) }
    var label: Style { Style(fg: dim, bg: appBg) }
    var muted: Style { Style(fg: faint, bg: appBg) }

    static let strict = Theme()
}
