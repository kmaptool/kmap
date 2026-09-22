import Foundation

/// A modal question drawn over the screen, with a title, wrapped body paragraphs, optional
/// label/value rows, and two buttons. The cursor starts on cancel, so confirming needs a
/// deliberate move. Drawn in DialogRender.
struct Dialog {
    enum Outcome: Equatable {
        case none
        case confirmed
        case cancelled
    }

    /// How the box is coloured: `danger` fills red, `plain` uses the interface greys.
    enum Tone {
        case danger
        case plain
    }

    enum Focus { case cancel, confirm }

    let title: String
    /// Paragraphs, wrapped to the box.
    let body: [String]
    /// Label and value rows drawn below the body.
    let detail: [(label: String, value: String)]
    let confirm: String
    let cancel: String
    let tone: Tone

    /// Which button has the cursor. Starts on cancel.
    private(set) var focus: Focus = .cancel

    init(
        title: String,
        body: [String],
        detail: [(label: String, value: String)] = [],
        confirm: String,
        cancel: String,
        tone: Tone = .danger
    ) {
        self.title = title
        self.body = body
        self.detail = detail
        self.confirm = confirm
        self.cancel = cancel
        self.tone = tone
    }

    /// Footer hints for the current focus. The Esc hint appears only while the cursor is
    /// on confirm.
    var footerHints: [Hint] {
        var hints = [
            Hint(key: "←→", label: t("choose")),
            Hint(key: Glyph.enter, label: focus == .confirm ? confirm : cancel)
        ]
        if focus == .confirm { hints.append(Hint(key: "esc", label: cancel)) }
        return hints
    }

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .left, .right, .tab, .backTab:
            focus = focus == .cancel ? .confirm : .cancel
        case .enter, .char(" "):
            return focus == .confirm ? .confirmed : .cancelled
        case .esc, .ctrl("c"):
            return .cancelled
        default:
            break
        }
        return .none
    }
}
