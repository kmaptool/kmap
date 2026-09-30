import Foundation

/// What a screen has to say on its last line: news, or a refusal in red.
struct Notice {
    private(set) var text: String?
    private(set) var isError = false

    mutating func say(_ text: String, error: Bool = false) {
        self.text = text
        isError = error
    }

    mutating func clear() { text = nil }

    func draw(into s: Surface, rect: Rect, theme: Theme) {
        s.statusLine(text, isError: isError, rect: rect, theme: theme)
    }
}
