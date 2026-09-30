import Foundation

/// A modal dialog together with what it is about: the row being deleted, the file being
/// imported. The two leave together, so the answer always names its subject.
struct Question<Subject> {
    var dialog: Dialog
    let subject: Subject

    var footerHints: [Hint] { dialog.footerHints }

    func render(into s: Surface, rect: Rect, theme: Theme) {
        dialog.render(into: s, rect: rect, theme: theme)
    }
}

extension Optional {
    /// Routes a key to the open question, if any. An answer closes it and comes back with
    /// the subject; nil when no question is up.
    mutating func take<S>(_ key: KeyEvent) -> (answer: Dialog.Outcome, subject: S)?
    where Wrapped == Question<S> {
        guard var open = self else { return nil }
        let answer = open.dialog.handle(key)
        self = answer == .none ? open : nil
        return (answer, open.subject)
    }
}
