import Foundation

/// What the pixel editor does with the keys, the prompts and the mouse.
extension PixelEditorScreen {
    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if picker != nil { return handlePicker(key) }
        if prompt != nil { return handlePrompt(key) }

        switch key {
        case .mouse(let event): handleMouse(event)
        case .tab, .backTab:
            focus = focus == .canvas ? .palette : .canvas
            message = nil
        case .up where focus == .palette:
            selected = max(0, selected - 1)
        case .down where focus == .palette:
            selected = min(shown.palette.count - 1, selected + 1)
        case .left where focus == .palette, .right where focus == .palette:
            focus = .canvas
        case .up: cursor.y = max(0, cursor.y - 1)
        case .down: cursor.y = min(shown.height - 1, cursor.y + 1)
        case .left: cursor.x = max(0, cursor.x - 1)
        case .right: cursor.x = min(shown.width - 1, cursor.x + 1)
        case .enter where focus == .palette:
            focus = .canvas
        case .char(" "), .enter:
            paint(x: cursor.x, y: cursor.y, with: selected)
        case .char(let typed) where typed.isNumber:
            let index = (typed.wholeNumberValue ?? 1) - 1
            if shown.palette.indices.contains(index) { selected = index }
        case .char(let typed):
            // By the key's place on the keyboard, not by its letter — see Keys.latin.
            switch Keys.latin(typed) {
            case "i": if let rows = grid() { selected = rows[cursor.y][cursor.x] }
            case "a": begin(.addColour)
            case "c": begin(.changeColour(index: selected))
            case "s" where canResize: begin(.size)
            case "n" where kind == .point: toggleNight()
            case "u": undo()
            case "[": selected = max(0, selected - 1)
            case "]": selected = min(shown.palette.count - 1, selected + 1)
            default: break
            }
        case .ctrl("s"): save()
        case .ctrl("c"): return .quit
        case .esc:
            guard dirty else { return .pop }
            begin(.confirmDiscard)
        default: break
        }
        return .none
    }

    private func begin(_ what: Prompt) {
        prompt = what
        message = nil
        switch what {
        case .addColour: draft = "#"
        case .changeColour(let index):
            draft = shown.palette[safe: index]?.colour ?? t("none")
        case .size: draft = "\(shown.width)x\(shown.height)"
        case .confirmDiscard: draft = ""
        }
    }

    private func handlePrompt(_ key: KeyEvent) -> Route {
        guard let what = prompt else { return .none }
        switch key {
        case .esc:
            prompt = nil
            draft = ""
        case .ctrl("p"):
            // Seeded with the picture's own colours as well as the spread: a new colour is
            // usually a neighbour of one already in the icon.
            if wantsColour {
                picker = ColourPicker(start: draft,
                                      palette: shown.palette.compactMap { $0.colour })
            }
        case .backspace:
            if !draft.isEmpty { draft.removeLast() }
        case .char(let c):
            if case .confirmDiscard = what {
                if Keys.latin(c) == "y" { return .pop }
                if Keys.latin(c) == "n" { prompt = nil }
                return .none
            }
            draft.append(c)
        case .enter:
            switch what {
            case .addColour: addColour(draft)
            case .changeColour(let index): changeColour(index, to: draft)
            case .size: resize(draft)
            case .confirmDiscard: return .pop
            }
            prompt = nil
            draft = ""
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func handlePicker(_ key: KeyEvent) -> Route {
        guard var open = picker else { return .none }
        switch open.handle(key) {
        case .chose(let colour): draft = colour; picker = nil
        case .cancelled: picker = nil
        case .none: picker = open
        }
        return .none
    }

    /// A click on the canvas paints; a click on the palette selects. Dragging paints, which
    /// is why motion reporting is enabled.
    private func handleMouse(_ event: MouseEvent) {
        switch event.action {
        case .move:
            // The cursor follows the pointer without painting, so the readout under the
            // canvas names the colour of the pixel being pointed at.
            if let pixel = pixel(at: event) { cursor = pixel }
        case .press, .drag:
            guard event.isPrimary else { return }
            if let pixel = pixel(at: event) {
                cursor = pixel
                paint(x: pixel.x, y: pixel.y, with: selected)
            } else if event.action == .press, let entry = paletteEntry(at: event) {
                selected = entry
            }
        case .scrollUp: selected = max(0, selected - 1)
        case .scrollDown: selected = min(shown.palette.count - 1, selected + 1)
        case .release: break
        }
    }

    private func pixel(at event: MouseEvent) -> (x: Int, y: Int)? {
        let x = (event.x - canvasOrigin.x) / 2
        let y = event.y - canvasOrigin.y
        guard x >= 0, x < shown.width, y >= 0, y < shown.height else { return nil }
        return (x, y)
    }

    private func paletteEntry(at event: MouseEvent) -> Int? {
        let row = event.y - paletteOrigin.y
        guard row >= 0, row < shown.palette.count, event.x >= paletteOrigin.x else { return nil }
        return row
    }
}
