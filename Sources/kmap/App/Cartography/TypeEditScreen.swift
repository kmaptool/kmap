import Foundation

/// Edit one type: its colours, its drawing, and the names the device prints for it.
///
/// Colours are day/night pairs, the night half blank where the file says nothing: absent
/// and same-as-day are different facts about the file. Each change rewrites one line of the
/// file in place, leaving the rest byte for byte as it was; there is no save step.
final class TypeEditScreen: Screen {

    var page: Page { Page(style.name, subject: TypeMeaning.hex(code), keys: keys) }

    private var keys: [Hint] {
        if picker != nil {
            return [Hint(key: "↑↓←→", label: t("move")),
                    Hint(key: Glyph.enter, label: t("take it")),
                    Hint(key: "esc", label: t("back to typing"))]
        }
        if editing != nil {
            return [Hint(key: Glyph.enter, label: t("apply")),
                    Hint(key: "^P", label: t("pick a colour")),
                    Hint(key: "esc", label: t("cancel"))]
        }
        var hints = [Hint(key: "↑↓", label: t("move"))]
        if case .colourPair = fields[safe: list.selected] {
            hints.append(Hint(key: "←→", label: t("day / night")))
        }
        hints.append(contentsOf: [Hint(key: Glyph.enter, label: t("change")),
                                  Hint(key: "esc", label: t("back"))])
        return hints
    }

    /// Something about this type a person can change.
    enum Field {
        /// The `Xpm` block: an icon, a pattern, or the solid colours standing in for one.
        case picture
        /// The same block, opened in the pixel editor.
        case drawPicture
        /// One role, with the colour it takes by day and the one it takes after dark.
        case colourPair(role: String, day: TypSection.ColourSlot,
                        night: TypSection.ColourSlot?)
        /// A point with no night picture at all, offering to start one from its day.
        case addNight
        /// A `String=` name, by language index.
        case label(language: Int, name: String)
        /// How the device sets the label: its size, and its colour by day and by night.
        case fontStyle
        case labelColour
    }

    /// What the compiler accepts for `FontStyle`. The empty first entry is the absence of
    /// the tag, which leaves the size to the receiver.
    static let fontStyles = ["", "NoLabel", "SmallFont", "NormalFont", "LargeFont"]

    let style: MapStyle
    let kind: MapElementKind
    let code: Int
    let onEdited: () -> Void

    var document: StyleDocument
    var list = ListState()
    var editing: Field?
    /// Which half of a colour pair the cursor is on.
    var onNight = false
    var draft = ""
    var picker: ColourPicker?
    var message: String?
    var messageIsError = false

    init(style: MapStyle, kind: MapElementKind, code: Int,
         onEdited: @escaping () -> Void) {
        self.style = style
        self.kind = kind
        self.code = code
        self.onEdited = onEdited
        self.document = StyleDocument.load(style)
    }

    var section: TypSection? { document.source?.section(kind, code) }

    var fields: [Field] {
        guard let section else { return [] }
        var out: [Field] = [.picture]
        // Offered for a solid type too: the drawing screen starts one of those from the
        // colour it already uses rather than from nothing.
        if section.kind != .point || section.picture != nil { out.append(.drawPicture) }

        let slots = section.colourSlots
        for (index, day) in slots.day.enumerated() {
            out.append(.colourPair(role: day.role, day: day,
                                   night: slots.night[safe: index]))
        }
        if section.kind == .point, section.dayXpm != nil, section.nightXpm == nil {
            out.append(.addNight)
        }

        // The names the file carries, by the language code the format numbers them with.
        // Both rows appear whatever language the interface is in.
        out.append(.label(language: 0x00, name: t("Name (English)")))
        out.append(.label(language: 0x19, name: t("Name (Russian)")))
        out.append(.fontStyle)
        // The label's own colour, not inherited from the line: omitted, the device chooses.
        out.append(.labelColour)
        return out
    }
}
