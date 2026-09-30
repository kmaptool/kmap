import Foundation

/// Moves one rule onto a different Garmin type. The unit moved is a rule and not a
/// code, since one code commonly carries several meanings.
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
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("choose")),
                Hint(key: "type", label: t("filter")),
                Hint(key: "esc", label: t("back"))
            ]
        case .rule:
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("choose")),
                Hint(key: "esc", label: t("back"))
            ]
        case .target:
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("reassign")),
                Hint(key: "type", label: t("filter")),
                Hint(key: Glyph.tab, label: typing ? t("back to the list") : t("type a code")),
                Hint(key: "esc", label: t("back"))
            ]
        }
    }

    enum Stage { case source, rule, target }

    /// Outside the POI category range a receiver draws the point but offers no card.
    static let poiCardRange = 0x29...0x30
    private static let noteLength = 50

    let document: StyleDocument
    let kind: MapElementKind
    /// The code whose rule is being moved: fixed in the forward gesture, chosen at the
    /// `.source` stage in the inverse one.
    var code: Int
    /// The inverse gesture's destination: a free code the feature is bound to.
    let fixedTarget: Int?
    private let onReassigned: () -> Void

    var stage: Stage = .rule
    var chosen: TypeMeaning.Rule?
    var typing = false
    var typed = ""
    /// The list and its filter, shared by every stage and reset between them.
    var filter = TypedFilter()
    var notice = Notice()

    init(document: StyleDocument, kind: MapElementKind, code: Int, onReassigned: @escaping () -> Void) {
        self.document = document
        self.kind = kind
        self.code = code
        self.fixedTarget = nil
        self.onReassigned = onReassigned
    }

    init(document: StyleDocument, kind: MapElementKind, bindingTo target: Int, onReassigned: @escaping () -> Void) {
        self.document = document
        self.kind = kind
        self.code = target
        self.fixedTarget = target
        self.onReassigned = onReassigned
        self.stage = .source
    }

    var rules: [TypeMeaning.Rule] {
        document.rules?.meaning(kind, code)?.rules ?? []
    }

    /// The kind never changes while this screen is open.
    private var cachedRows: [StyleTypeRow]?
    var rows: [StyleTypeRow] {
        if let cachedRows { return cachedRows }
        let read = document.rows(kind)
        cachedRows = read
        return read
    }

    private func filtered(_ candidates: [StyleTypeRow]) -> [StyleTypeRow] {
        guard !filter.isEmpty else { return candidates }
        return candidates.filter { filter.matches([$0.hex, $0.name(preferringRussian: true)] + $0.tags) }
    }

    /// What can be bound here: every code some rule emits.
    var sources: [StyleTypeRow] {
        filtered(rows.filter { $0.isEmitted && $0.code != fixedTarget })
    }

    var targets: [StyleTypeRow] {
        filtered(rows.filter { $0.code != code })
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
        if filter.take(key, count: sources.count) { return .none }
        switch key {
        case .enter:
            guard let row = sources[safe: filter.list.selected] else { return .none }
            code = row.code
            go(to: .rule)
        case .esc:
            if filter.clear() { return .none }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func handleRule(_ key: KeyEvent) -> Route {
        let rules = self.rules
        switch key {
        case .up: filter.list.move(-1, count: rules.count)
        case .down: filter.list.move(1, count: rules.count)
        case .enter:
            guard let rule = rules[safe: filter.list.selected] else { return .none }
            if let problem = objection(to: rule) {
                notice.say(problem, error: true)
                return .none
            }
            chosen = rule
            // The inverse gesture already knows where.
            if let fixedTarget { return commit(to: fixedTarget) }
            go(to: .target)
        case .esc:
            if fixedTarget != nil {
                go(to: .source)
                return .none
            }
            return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func go(to next: Stage) {
        stage = next
        filter.list = ListState()
        notice.clear()
    }

    /// A reassignment substitutes one exact line: a rule absent from the file, or present
    /// more than once, is refused.
    private func objection(to rule: TypeMeaning.Rule) -> String? {
        let url = (document.style.styleDirectory ?? StyleCatalog.baseStyleDirectory).appendingPathComponent(
            kind.ruleFile
        )
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return t("the rule set has not been unpacked yet — run a build once")
        }
        switch RuleSetIndex.occurrences(of: rule.raw, in: text) {
        case 0:
            return t(
                "this rule is not in %@ as written — it may come from an include, which cannot be substituted",
                kind.ruleFile
            )
        case 1:
            return nil
        default:
            return t("this exact rule appears more than once in %@; moving it would move every copy", kind.ruleFile)
        }
    }

    private func handleTarget(_ key: KeyEvent) -> Route {
        switch key {
        case .tab, .backTab:
            typing.toggle()
            notice.clear()
        case .backspace where typing:
            if !typed.isEmpty { typed.removeLast() }
        case .char(let c) where typing:
            typed.append(c)
        case .enter:
            if typing {
                guard let target = Self.parseCode(typed) else {
                    notice.say(t("%@ is not a type code — write it as 0x2f01", typed), error: true)
                    return .none
                }
                return commit(to: target)
            }
            guard let row = targets[safe: filter.list.selected] else { return .none }
            return commit(to: row.code)
        case .esc:
            if typing { typing = false; return .none }
            if filter.clear() { return .none }
            stage = .rule
            filter.list = ListState()
        case .ctrl("c"): return .quit
        default:
            if !typing { _ = filter.take(key, count: targets.count) }
        }
        return .none
    }

    static func parseCode(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard !t.isEmpty, let value = Int(t, radix: 16), value > 0 else { return nil }
        return value
    }

    private func commit(to target: Int) -> Route {
        guard let rule = chosen else { return .none }
        // A record on disk, so it stays English whatever the interface speaks.
        let note =
            "was \(TypeMeaning.hex(code))"
            + (rule.condition.isEmpty ? "" : " · \(truncate(rule.condition, to: Self.noteLength))")
        do {
            try RuleReassignments.add(
                RuleReassignment(file: kind.ruleFile, raw: rule.raw, fromCode: code, toCode: target, note: note)
            )
            onReassigned()
            return .pop
        } catch {
            notice.say(error.localizedDescription, error: true)
            return .none
        }
    }
}
