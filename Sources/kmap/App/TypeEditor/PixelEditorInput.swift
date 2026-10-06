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
            switch Keys.latin(typed) {
            case "i": if let picked = grid()?[safe: cursor.y]?[safe: cursor.x] { selected = picked }
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
        case .ctrl("c"):
            // Asked as Esc asks: the strokes are not saved anywhere else.
            guard dirty else { return .quit }
            begin(.confirmDiscard(quitting: true))
        case .esc:
            guard dirty else { return .pop }
            begin(.confirmDiscard(quitting: false))
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
        // Only y leaves: Enter paints, and a reflexive one must not throw strokes away.
        if case .confirmDiscard(let quitting) = what {
            switch YesNo.answer(key) {
            case .yes: return quitting ? .quit : .pop
            case .no: prompt = nil
            case .quit: return .quit
            case nil: break
            }
            return .none
        }
        switch key {
        case .esc:
            prompt = nil
            draft = ""
        case .ctrl("p"):
            // Seeded with the picture's own colours: a new one is usually a neighbour.
            if wantsColour {
                picker = ColourPicker(start: draft, palette: shown.palette.compactMap { $0.colour })
            }
        case .backspace:
            if !draft.isEmpty { draft.removeLast() }
        case .char(let c):
            draft.append(c)
        case .paste(let text):
            draft += text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        case .enter:
            switch what {
            case .addColour: addColour(draft)
            case .changeColour(let index): changeColour(index, to: draft)
            case .size: resize(draft)
            case .confirmDiscard: return .none
            }
            prompt = nil
            draft = ""
        case .ctrl("c"):
            // From a prompt as from the canvas: unsaved strokes are asked about.
            guard dirty else { return .quit }
            draft = ""
            prompt = .confirmDiscard(quitting: true)
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

    /// A click on the canvas paints, a click on the palette selects, dragging paints.
    private func handleMouse(_ event: MouseEvent) {
        switch event.action {
        case .move:
            // The readout under the canvas names the pixel being pointed at.
            if let pixel = pixel(at: event) { cursor = pixel }
        case .press, .drag:
            guard event.isPrimary else { return }
            if event.action == .press { strokeRemembered = false }
            if let pixel = pixel(at: event) {
                cursor = pixel
                // A stroke is undone whole: remembered at the first pixel it changes,
                // wherever the press was.
                if paint(x: pixel.x, y: pixel.y, with: selected, remembering: !strokeRemembered) {
                    strokeRemembered = true
                }
            } else if event.action == .press, let entry = paletteEntry(at: event) {
                selected = entry
            }
        case .scrollUp: selected = max(0, selected - 1)
        case .scrollDown: selected = min(shown.palette.count - 1, selected + 1)
        case .release: break
        }
    }

    private func pixel(at event: MouseEvent) -> (x: Int, y: Int)? {
        // Left of the canvas first: -1 / 2 is 0 in Swift, which is a column.
        guard event.x >= canvasOrigin.x, event.y >= canvasOrigin.y else { return nil }
        // Within the window drawn: the palette beside it is not a hidden pixel.
        let column = (event.x - canvasOrigin.x) / 2
        let row = event.y - canvasOrigin.y
        guard column < canvasShown.across, row < canvasShown.down else { return nil }
        let x = column + canvasScroll.x
        let y = row + canvasScroll.y
        guard x < shown.width, y < shown.height else { return nil }
        return (x, y)
    }

    private func paletteEntry(at event: MouseEvent) -> Int? {
        let row = event.y - paletteOrigin.y
        guard row >= 0, row < paletteShown, event.x >= paletteOrigin.x else { return nil }
        let entry = row + paletteScroll
        return entry < shown.palette.count ? entry : nil
    }
}
