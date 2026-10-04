import Foundation

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
