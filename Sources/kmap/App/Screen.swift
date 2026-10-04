import Foundation

/// A footer hint shown in the bottom bar.
struct Hint {
    let key: String
    let label: String
}

/// One full-screen view in the navigation stack, driven by the render loop on the main actor.
@MainActor
protocol Screen: AnyObject {
    var page: Page { get }
    /// Every frame before rendering, for polling background state.
    func tick(_ ctx: AppContext)
    func render(into surface: Surface, rect: Rect, ctx: AppContext)
    /// A second pass over header, content and footer: an open list, a dialog.
    func renderOverlay(into surface: Surface, rect: Rect, ctx: AppContext)
    func handle(_ key: KeyEvent, ctx: AppContext) -> Route
    /// Pointer reports disable the terminal's own text selection, so off by default.
    var wantsMouse: Bool { get }
}

extension Screen {
    var title: String { page.title }
    var footerHints: [Hint] { page.keys }

    func tick(_ ctx: AppContext) {}
    func renderOverlay(into surface: Surface, rect: Rect, ctx: AppContext) {}
    var wantsMouse: Bool { false }
}
