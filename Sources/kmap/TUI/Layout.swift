import Foundation

/// Shared column measurements for screens laid out as a form with an optional side panel.
enum Layout {
    /// The greatest width a form is given, in cells.
    static let formWidth = 64

    /// The width reserved for a side panel.
    static let panelWidth = 40

    /// The least total width at which a panel is shown at all.
    static let panelNeeds = 100

    /// The gap between form and panel, holding the dividing rule.
    static let gutter = 3

    /// The width of a field's label column, common to every form.
    static let fieldLabel = 18

    /// Splits `rect` into a form and the panel beside it, or into the form alone when
    /// there is no room for a panel.
    static func split(_ rect: Rect) -> (form: Rect, panel: Rect?) {
        let hasPanel = rect.w >= panelNeeds
        let width = min(formWidth, rect.w - (hasPanel ? panelWidth : 0))
        let form = Rect(x: rect.x, y: rect.y, w: width, h: rect.h)
        guard hasPanel else { return (form, nil) }
        return (form, Rect(x: rect.x + width + gutter, y: rect.y,
                           w: rect.w - width - gutter, h: rect.h))
    }
}
