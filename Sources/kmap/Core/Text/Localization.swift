import Foundation

/// The language the interface speaks. It affects no build output: map labels follow the
/// recipe's `Labels` field and the code page.
enum Lang: String, CaseIterable, Codable {
    case en, ru

    /// The language's endonym, for a language picker.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    /// Returns the first of `preferred` that is a supported language, else `.en`. Tags are
    /// matched on their base subtag.
    static func fromSystem(_ preferred: [String] = Locale.preferredLanguages) -> Lang {
        for tag in preferred {
            guard let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first?.lowercased() else { continue }
            if let match = Lang(rawValue: base) { return match }
        }
        return .en
    }
}

/// The interface's text in the current language. English is the source language and has no
/// entries: a key is its own English text, so an untranslated string reads as English. The
/// tables are compiled in, in `Strings`.
enum L10n {

    /// The current language. Read from any thread and written from the main one, so every
    /// access is under `gate`.
    private static let gate = NSLock()
    nonisolated(unsafe) private static var chosen: Lang = .en

    static var current: Lang {
        gate.lock()
        defer { gate.unlock() }
        return chosen
    }

    private static func choose(_ language: Lang) {
        gate.lock()
        chosen = language
        gate.unlock()
    }

    /// Resolves the language for this run from a stored value and the system list.
    ///
    /// - Returns: The language, and whether it must be written to settings.
    static func resolve(stored: String,
                        system: [String] = Locale.preferredLanguages)
        -> (language: Lang, store: Bool) {
        if let known = Lang(rawValue: stored) { return (known, false) }
        // Nothing stored, or an unknown value: the system list decides, and is stored.
        return (Lang.fromSystem(system), true)
    }

    /// Sets the language for this run from the stored choice, writing the system's answer to
    /// settings where nothing was stored.
    @discardableResult
    static func bootstrap(_ store: SettingsStore) -> Lang {
        let decision = resolve(stored: store.settings.uiLanguage)
        choose(decision.language)
        if decision.store {
            store.update { $0.uiLanguage = decision.language.rawValue }
        }
        return decision.language
    }

    static func use(_ language: Lang, in store: SettingsStore? = nil) {
        choose(language)
        store?.update { $0.uiLanguage = language.rawValue }
    }

    // MARK: Lookup

    static func text(_ key: String) -> String {
        spelling(Strings.text(key, in: current) ?? key)
    }

    /// Returns `text` with the key names a console cannot draw spelled out. A sentence
    /// asking for ⏎ says Enter on Windows; everywhere else the glyph stands.
    static func spelling(_ text: String) -> String {
        #if os(Windows)
        return keyNames(in: text)
        #else
        return text
        #endif
    }

    /// The substitution itself, built on every platform so it can be tested on any.
    static func keyNames(in text: String) -> String {
        guard text.contains("⏎") || text.contains("⇥") else { return text }
        return text.replacingOccurrences(of: "⏎", with: "Enter")
                   .replacingOccurrences(of: "⇥", with: "Tab")
    }

    /// Returns the form of `key` that goes with `count`, falling back to the "other"
    /// form, then to the flat translation, then to `key`.
    static func text(_ key: String, count: Int) -> String {
        if let forms = Strings.plural(key, in: current) {
            if let exact = forms[plural(count, in: current)] { return spelling(exact) }
            if let other = forms["other"] { return spelling(other) }
        }
        // No plural entry: the flat translation, then the key itself, both spelled there.
        return text(key)
    }

    /// Returns the CLDR plural category of `count`, with rules for the supported languages
    /// only.
    static func plural(_ count: Int, in language: Lang) -> String {
        let n = abs(count)
        switch language {
        case .en:
            return n == 1 ? "one" : "other"
        case .ru:
            let mod10 = n % 10
            let mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return "one" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
            return "many"
        }
    }
}

// MARK: - What the screens call

/// Returns the interface text for `key` in the current language. A key is its own English
/// text.
func t(_ key: String) -> String {
    L10n.text(key)
}

/// Returns the interface text for `key` with `first` and `rest` formatted into it. The
/// placeholders belong to the translated string, so a translation may reorder them.
func t(_ key: String, _ first: CVarArg, _ rest: CVarArg...) -> String {
    String(format: L10n.text(key), arguments: [first] + rest)
}

/// Returns the plural form of `key` for `count`, with `count` formatted into it.
func tn(_ key: String, _ count: Int) -> String {
    String(format: L10n.text(key, count: count), arguments: [count])
}

/// Returns the plural form of `key` for `count`, with `count` and `rest` formatted in.
func tn(_ key: String, _ count: Int, _ rest: CVarArg...) -> String {
    String(format: L10n.text(key, count: count), arguments: [count] + rest)
}

/// Whether `text` means "no colour". Accepts both the translated word and the TYP format's
/// own `none`, in every language.
func meansNone(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespaces).lowercased()
    return value == "none" || value == t("none").lowercased()
}
