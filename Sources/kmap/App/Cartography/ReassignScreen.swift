import Foundation

/// Moves one rule onto a different Garmin type.
///
/// A TYP decides how a code is drawn; the rule set decides which code a feature gets. The
/// unit moved is a rule and not a code, since one code commonly carries several meanings.
final class ReassignScreen: Screen {

    var page: Page {
        let subject: String
        switch stage {
        case .source: subject = t("which feature")
        case .rule: subject = t("which rule")
        case .target: subject = t("where to")
        }
        return Page(t("reassign"), subject: subject, keys: keys)
    }

    private var keys: [Hint] {
        switch stage {
        case .source:
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("choose")),
                    Hint(key: "type", label: t("filter")),
                    Hint(key: "esc", label: t("back"))]
        case .rule:
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("choose")),
                    Hint(key: "esc", label: t("back"))]
        case .target:
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("reassign")),
                    Hint(key: "type", label: t("filter")),
                    Hint(key: Glyph.tab, label: typing ? t("back to the list") : t("type a code")),
                    Hint(key: "esc", label: t("back"))]
        }
    }

    private enum Stage { case source, rule, target }

    /// The POI category range. Outside it a receiver draws the point but offers no card;
    /// the mkgmap `PlacesFile` indexes only `type >> 8` within 0x29…0x30.
    private static let poiCardRange = 0x29...0x30

    private let document: StyleDocument
    private let kind: MapElementKind
    /// The code whose rule is being moved. Fixed in the forward gesture; chosen at
    /// the `.source` stage in the inverse one.
    private var code: Int
    /// The inverse gesture's destination: `x` pressed on a free code fixes it as the
    /// target, and the flow asks which feature to bind there instead of where to go.
    private let fixedTarget: Int?
    private let onReassigned: () -> Void

    private var stage: Stage = .rule
    private var chosen: TypeMeaning.Rule?
    private var typing = false
    private var typed = ""
    private var list = ListState()
    private var query = ""
    private var message: String?
    private var messageIsError = false

    init(document: StyleDocument, kind: MapElementKind, code: Int,
         onReassigned: @escaping () -> Void) {
        self.document = document
        self.kind = kind
        self.code = code
        self.fixedTarget = nil
        self.onReassigned = onReassigned
    }

    /// The inverse gesture: stand on a free code and bind a feature to it. The flow
    /// runs source → rule, and the reassignment lands on `target`.
    init(document: StyleDocument, kind: MapElementKind, bindingTo target: Int,
         onReassigned: @escaping () -> Void) {
        self.document = document
        self.kind = kind
        self.code = target
        self.fixedTarget = target
        self.onReassigned = onReassigned
        self.stage = .source
    }

    private var rules: [TypeMeaning.Rule] {
        document.rules?.meaning(kind, code)?.rules ?? []
    }

    /// The kind never changes while this screen is open, so its rows are read once rather
    /// than looked up every frame.
    private var cachedRows: [StyleTypeRow]?
    private var rows: [StyleTypeRow] {
        if let cachedRows { return cachedRows }
        let read = document.rows(kind)
        cachedRows = read
        return read
    }

    /// What can be bound here: every code some rule emits, searchable the way the
    /// targets are.
    private var sources: [StyleTypeRow] {
        let all = rows.filter { $0.isEmitted && $0.code != fixedTarget }
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter {
            $0.hex.contains(q)
                || $0.name(preferringRussian: true).lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private var targets: [StyleTypeRow] {
        let all = rows.filter { $0.code != code }
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter {
            $0.hex.contains(q)
                || $0.name(preferringRussian: true).lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch stage {
        case .source: return handleSource(key)
        case .rule: return handleRule(key)
        case .target: return handleTarget(key)
        }
    }

    private func handleSource(_ key: KeyEvent) -> Route {
        switch key {
        case .up: list.move(-1, count: sources.count)
        case .down: list.move(1, count: sources.count)
        case .pageUp: list.move(-10, count: sources.count, wrap: false)
        case .pageDown: list.move(10, count: sources.count, wrap: false)
        case .backspace:
            if !query.isEmpty { query.removeLast(); list.selected = 0 }
        case .char(let c): query.append(c); list.selected = 0
        case .enter:
            guard let row = sources[safe: list.selected] else { return .none }
            code = row.code
            stage = .rule
            list = ListState()
            message = nil
        case .esc:
            if !query.isEmpty { query = ""; list.selected = 0; return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func handleRule(_ key: KeyEvent) -> Route {
        let rules = self.rules
        switch key {
        case .up: list.move(-1, count: rules.count)
        case .down: list.move(1, count: rules.count)
        case .enter:
            guard let rule = rules[safe: list.selected] else { return .none }
            guard let problem = objection(to: rule) else {
                chosen = rule
                // The inverse gesture already knows where: the code it was opened on.
                if let fixedTarget { return commit(to: fixedTarget) }
                stage = .target
                list = ListState()
                message = nil
                return .none
            }
            message = problem
            messageIsError = true
        case .esc:
            if fixedTarget != nil {
                stage = .source
                list = ListState()
                message = nil
                return .none
            }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Why this rule cannot be moved, if it cannot: a reassignment substitutes one exact
    /// line, so a rule that is absent from the file, or present more than once, is refused.
    private func objection(to rule: TypeMeaning.Rule) -> String? {
        let url = (document.style.styleDirectory ?? StyleCatalog.baseStyleDirectory)
            .appendingPathComponent(kind.ruleFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return t("the rule set has not been unpacked yet — run a build once")
        }
        switch RuleSetIndex.occurrences(of: rule.raw, in: text) {
        case 0:
            return t("this rule is not in %@ as written — it may come from an "
                   + "include, which cannot be substituted", kind.ruleFile)
        case 1:
            return nil
        default:
            return t("this exact rule appears more than once in %@; moving it "
                   + "would move every copy", kind.ruleFile)
        }
    }

    private func handleTarget(_ key: KeyEvent) -> Route {
        switch key {
        case .tab, .backTab:
            typing.toggle()
            message = nil
        case .up where !typing: list.move(-1, count: targets.count)
        case .down where !typing: list.move(1, count: targets.count)
        case .pageUp where !typing: list.move(-10, count: targets.count, wrap: false)
        case .pageDown where !typing: list.move(10, count: targets.count, wrap: false)
        case .backspace:
            if typing { if !typed.isEmpty { typed.removeLast() } }
            else if !query.isEmpty { query.removeLast(); list.selected = 0 }
        case .char(let c):
            if typing { typed.append(c) } else { query.append(c); list.selected = 0 }
        case .enter:
            if typing {
                guard let target = parseCode(typed) else {
                    message = t("%@ is not a type code — write it as 0x2f01", typed)
                    messageIsError = true
                    return .none
                }
                return commit(to: target)
            }
            guard let row = targets[safe: list.selected] else { return .none }
            return commit(to: row.code)
        case .esc:
            if typing { typing = false; return .none }
            if !query.isEmpty { query = ""; list.selected = 0; return .none }
            stage = .rule
            list = ListState()
            return .none
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func parseCode(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard !t.isEmpty, let value = Int(t, radix: 16), value > 0 else { return nil }
        return value
    }

    private func commit(to target: Int) -> Route {
        guard let rule = chosen else { return .none }
        // Written into the reassignments file, a record on disk, so it stays English
        // whatever language the interface is using.
        let note = "was \(TypeMeaning.hex(code))"
            + (rule.condition.isEmpty ? "" : " · \(truncate(rule.condition, to: 50))")

        do {
            try RuleReassignments.add(RuleReassignment(
                file: kind.ruleFile, raw: rule.raw,
                fromCode: code, toCode: target, note: note))
            onReassigned()
            return .pop
        } catch {
            message = error.localizedDescription
            messageIsError = true
            return .none
        }
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        switch stage {
        case .source: renderSources(s, rect: rect, theme: ctx.theme)
        case .rule: renderRules(s, rect: rect, theme: ctx.theme)
        case .target: renderTargets(s, rect: rect, theme: ctx.theme)
        }
    }

    private func renderSources(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        for chunk in wrapText(
            t("%@ is free. Pick the feature to bind to it — its rule moves here and "
            + "takes effect on the next build.", TypeMeaning.hex(fixedTarget ?? code)),
            width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1
        let shown = sources
        let fx = s.text(rect.x, y, t("filter") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(fx, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        s.textRight(rect.maxX, y, tn("%d feature(s)", shown.count),
                    Style(fg: theme.faint, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        guard !shown.isEmpty else {
            s.text(rect.x, y, t("nothing matches"), Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        list.clamp(count: shown.count, visible: max(1, rect.maxY - y - 1))
        for i in 0..<min(max(1, rect.maxY - y - 1), shown.count - list.offset) {
            let index = list.offset + i
            guard let row = shown[safe: index] else { break }
            let trailing = truncate(row.tags.joined(separator: ", "), to: rect.w / 2)
            Widgets.row(s, rect: Rect(x: rect.x, y: y + i, w: rect.w, h: 1), y: y + i,
                        text: "\(row.hex)  \(row.name(preferringRussian: true))",
                        trailing: trailing,
                        theme: theme, selected: index == list.selected)
        }
        drawMessage(s, rect: rect, theme: theme)
    }

    private func renderRules(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        let rules = self.rules

        for chunk in wrapText(
            t("Moving a rule changes which Garmin type the thing gets — the "
            + "map, not the drawing. It takes effect on the next build, "
            + "and undoing it puts the rule back where mkgmap had it."),
            width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        s.text(rect.x, y, tn("%2$@ is emitted by %1$d rule(s):", rules.count,
                             TypeMeaning.hex(code)),
               Style(fg: theme.text, bg: theme.appBg))
        y += 1

        guard !rules.isEmpty else {
            s.text(rect.x, y, t("no rule in this style emits it — nothing to move"),
                   Style(fg: theme.warn, bg: theme.appBg))
            return
        }

        list.clamp(count: rules.count, visible: max(1, rect.maxY - y - 2))
        for (index, rule) in rules.enumerated() {
            guard y < rect.maxY - 1 else { break }
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: 1), y: y,
                        text: rule.condition, trailing: rule.tail,
                        theme: theme, selected: index == list.selected)
            y += 1
        }
        drawMessage(s, rect: rect, theme: theme)
    }

    private func renderTargets(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        if let chosen {
            let x = s.text(rect.x, y, t("moving") + " ", Style(fg: theme.dim, bg: theme.appBg))
            s.text(x, y, truncate(chosen.condition, to: max(0, rect.maxX - x - 12)),
                   Style(fg: theme.text, bg: theme.appBg))
            s.textRight(rect.maxX, y, t("off %@", TypeMeaning.hex(code)),
                        Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }

        if typing {
            s.text(rect.x, y, t("New type code:"), Style(fg: theme.text, bg: theme.appBg))
            y += 1
            let end = s.text(rect.x, y, typed,
                             Style(fg: theme.strong, bg: theme.appBg, bold: true))
            s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
            y += 2
            if let target = parseCode(typed) {
                y = warnings(about: target, into: s, rect: rect, y: y, theme: theme)
            } else {
                s.text(rect.x, y, t("written the way the rule files write it, such as 0x2f01"),
                       Style(fg: theme.faint, bg: theme.appBg))
            }
            drawMessage(s, rect: rect, theme: theme)
            return
        }

        let shown = targets
        let fx = s.text(rect.x, y, t("filter") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        let end = s.text(fx, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        s.textRight(rect.maxX, y, tn("%d known code(s)", shown.count),
                    Style(fg: theme.faint, bg: theme.appBg))
        y += 1
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        guard !shown.isEmpty else {
            s.text(rect.x, y, t("nothing matches — press ⇥ to type a code instead"),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        let noteHeight = 6
        let listHeight = max(1, rect.maxY - y - noteHeight - 1)
        list.clamp(count: shown.count, visible: listHeight)
        let listTop = y

        for i in 0..<min(listHeight, shown.count - list.offset) {
            let index = list.offset + i
            guard let row = shown[safe: index] else { break }
            let bg = index == list.selected ? theme.selectionBg : theme.appBg
            s.fill(Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), Style(fg: theme.text, bg: bg))
            var x = s.text(rect.x, y, index == list.selected ? "\(Glyph.arrowRight) " : "  ",
                           Style(fg: theme.accent, bg: bg))
            x = s.text(x, y, row.hex.padding(toLength: 8, withPad: " ", startingAt: 0),
                       Style(fg: row.isStyled ? theme.text : theme.faint, bg: bg))
            x = s.text(x, y, truncate(row.name(preferringRussian: true), to: 26)
                        .padding(toLength: 26, withPad: " ", startingAt: 0),
                       Style(fg: theme.text, bg: bg, bold: index == list.selected))
            let note = row.isStyled ? "" : t("device default")
            let room = max(0, rect.maxX - 1 - x - note.count - 2)
            s.text(x, y, truncate(row.tags.joined(separator: ", "), to: room),
                   Style(fg: theme.faint, bg: bg))
            if !note.isEmpty {
                s.textRight(rect.maxX - 1, y, note, Style(fg: theme.warn, bg: bg))
            }
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: shown.count,
                           visible: listHeight, theme: theme)

        if let row = shown[safe: list.selected] {
            s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
            _ = warnings(about: row.code, into: s, rect: rect, y: y + 1, theme: theme)
        }
        drawMessage(s, rect: rect, theme: theme)
    }

    /// What moving onto this code would mean. Said before the move, not after.
    private func warnings(about target: Int, into s: Surface, rect: Rect, y: Int,
                          theme: Theme) -> Int {
        var y = y
        let row = rows.first { $0.code == target }

        // Not recoverable by styling: outside the POI category range a receiver draws the
        // point and offers no card at all.
        if kind == .point, !ReassignScreen.poiCardRange.contains(target >> 8), y < rect.maxY {
            s.text(rect.x, y, t("outside the POI range 0x2900–0x30ff — the device will draw it "
                              + "but show no card for it"),
                   Style(fg: theme.danger, bg: theme.appBg))
            y += 1
        }
        if row?.isStyled != true, y < rect.maxY {
            s.text(rect.x, y, t("this TYP has no section for it — the device draws its own idea"),
                   Style(fg: theme.warn, bg: theme.appBg))
            y += 1
        }
        if let row, !row.tags.isEmpty, y < rect.maxY {
            s.text(rect.x, y, truncate(t("already carries") + ": "
                                       + row.tags.joined(separator: ", "),
                                       to: rect.w),
                   Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }
        return y
    }

    private func drawMessage(_ s: Surface, rect: Rect, theme: Theme) {
        guard let message else { return }
        s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
               Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
    }
}
