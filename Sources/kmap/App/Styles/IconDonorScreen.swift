import Foundation

/// Takes a drawing from another style or from a file, both at true size: a donor drawn
/// for a different size is offered with its size stated and used as it is.
final class IconDonorScreen: Screen {
    var page: Page {
        let subject: String
        switch stage {
        case .style: subject = t("from which style")
        case .type: subject = donorName
        case .file: subject = t("from a file")
        }
        return Page(t("borrow a drawing"), subject: subject, keys: keys)
    }

    private var keys: [Hint] {
        switch stage {
        case .style:
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("open")),
                Hint(key: "esc", label: t("back"))
            ]
        case .file:
            var hints = [Hint(key: Glyph.enter, label: loaded == nil ? t("load") : t("use this one"))]
            if FilePicker.isAvailable { hints.append(Hint(key: "^O", label: t("browse"))) }
            hints.append(Hint(key: Glyph.tab, label: t("back to the styles")))
            hints.append(Hint(key: "esc", label: t("back")))
            return hints
        case .type:
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("use this one")),
                Hint(key: "abc", label: t("filter")),
                Hint(key: "esc", label: t("back to the list"))
            ]
        }
    }

    enum Stage { case style, type, file }

    /// What a picture on disk is read at when nothing is being replaced.
    static let defaultIconSize = 20
    static let pictureExtensions = ["png", "jpg", "jpeg", "svg", "gif", "tif", "tiff", "bmp"]

    let kind: MapElementKind
    let target: TypSection?
    private let onPick: (XpmBlock) -> Void

    var stage: Stage = .style
    var styles: [MapStyle] = []
    var donorName = ""
    var donorSections: [TypSection] = []
    /// The source rows, and the types of the open donor.
    var list = ListState()
    var filter = TypedFilter()
    var message: String?
    /// The path being typed, and what came of loading it.
    var path = ""
    var loaded: IconImport.Result?

    /// - Parameter target: the section being replaced, for showing what is there now.
    init(kind: MapElementKind, target: TypSection?, onPick: @escaping (XpmBlock) -> Void) {
        self.kind = kind
        self.target = target
        self.onPick = onPick
    }

    /// The size a picture is read at: what it would replace.
    var wantedSize: Int { target?.picture?.width ?? Self.defaultIconSize }

    /// Only styles whose TYP is source text; a compiled one has nothing to offer.
    func tick(_ ctx: AppContext) {
        guard styles.isEmpty else { return }
        styles = ctx.styles.styles().list.filter { $0.typURL?.pathExtension.lowercased() == "txt" }
    }

    var visibleSections: [TypSection] {
        guard !filter.isEmpty else { return donorSections }
        return donorSections.filter { filter.matches([$0.hex, $0.englishLabel ?? "", $0.russianLabel ?? ""]) }
    }

    /// A file on disk, then one row per readable style.
    var sourceRowCount: Int { styles.count + 1 }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch stage {
        case .style: return handleStyle(key)
        case .type: return handleType(key)
        case .file: return handleFile(key)
        }
    }

    private func handleStyle(_ key: KeyEvent) -> Route {
        switch key {
        case .tab, .backTab:
            toFile()
        case .up: list.move(-1, count: sourceRowCount)
        case .down: list.move(1, count: sourceRowCount)
        case .enter:
            guard list.selected > 0 else {
                toFile()
                return .none
            }
            guard let style = styles[safe: list.selected - 1] else { return .none }
            open(style)
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// A picture file gives only a point its icon: said before a path is typed, not after.
    private func toFile() {
        guard kind == .point else {
            message = t("a picture file gives a point its icon — lines and areas borrow another style's drawing")
            return
        }
        stage = .file
        message = nil
    }

    private func open(_ style: MapStyle) {
        guard let url = style.typURL, let source = TypSource.read(url) else {
            message = t("%@ could not be read", style.name)
            return
        }
        donorName = style.name
        // Only sections carrying a picture; colours alone have nothing to lend.
        donorSections = source.sections(kind).filter { $0.picture != nil }
        stage = .type
        filter.reset()
        message = donorSections.isEmpty ? t("%1$@ has no %2$@ to lend", style.name, kind.plural) : nil
    }

    private func handleType(_ key: KeyEvent) -> Route {
        let shown = visibleSections
        if filter.take(key, count: shown.count) { return .none }
        switch key {
        case .enter:
            guard let picture = shown[safe: filter.list.selected]?.picture else { return .none }
            onPick(picture)
            return .pop
        case .esc:
            if filter.clear() { return .none }
            stage = .style
            list = ListState()
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Loading and using a file are separate keystrokes, so the result is seen first.
    private func handleFile(_ key: KeyEvent) -> Route {
        switch key {
        case .ctrl("o"):
            if let chosen = FilePicker.choose(
                .file(extensions: Self.pictureExtensions),
                startingAt: nil,
                prompt: t("take an icon from a file")
            ) {
                path = chosen.nativePath
                loaded = nil
                message = nil
            }
        case .tab, .backTab:
            stage = .style
            message = nil
        case .backspace:
            if !path.isEmpty { path.removeLast(); loaded = nil }
        case .char(let c):
            path.append(c)
            loaded = nil
        case .paste(let text):
            path += text.replacingOccurrences(of: "\n", with: "")
            loaded = nil
        case .enter:
            if let loaded {
                onPick(loaded.block)
                return .pop
            }
            load()
        // Back a step, as from a style's types.
        case .esc:
            stage = .style
            message = nil
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func load() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A picture file is read square, which only a point's icon may be: a pattern is
        // 32 wide and a line at most 31 high, so those come from another style's drawing.
        guard kind == .point else {
            loaded = nil
            message = t("a picture file gives a point its icon — lines and areas borrow another style's drawing")
            return
        }
        do {
            loaded = try IconImport.load(Paths.expand(trimmed), size: wantedSize)
            message = nil
        } catch {
            loaded = nil
            message = error.localizedDescription
        }
    }
}
