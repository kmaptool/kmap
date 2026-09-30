import Foundation

/// What a screen wants the navigator to do after handling a key.
enum Route {
    case none
    case push(Screen)
    case pop
    case popToRoot
    case replace(Screen)
    case quit
}

/// A footer hint shown in the bottom bar.
struct Hint {
    let key: String
    let label: String
}

/// A screen's title and footer keys, declared in one place.
struct Page {
    /// The screen's own name.
    var name: String
    /// What it is showing at this moment, or nil where the screen is only ever itself.
    var subject: String?
    /// The footer keys, in the order they are offered.
    var keys: [Hint]

    init(_ name: String, subject: String? = nil, keys: [Hint] = []) {
        self.name = name
        self.subject = subject
        self.keys = keys
    }

    /// Name and subject, separated by a middle dot.
    var title: String {
        guard let subject, !subject.isEmpty else { return name }
        return "\(name) · \(subject)"
    }
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
