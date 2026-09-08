import XCTest
@testable import kmap

/// The string tables against the sources that use them: a `t("…")` with no entry behind it
/// neither crashes nor warns, so the sources are scanned and every key must have an answer.
final class StringTablesTests: XCTestCase {

    /// The source tree, found by walking up from `#filePath` to `Package.swift`: a path
    /// counted in directories would yield an enumerator over nothing rather than an error.
    private static var sourcesDirectory: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.appendingPathComponent("Sources/kmap", isDirectory: true)
            }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// One key a source file asks for, and whether it asked by count.
    private struct Ask: Hashable {
        let key: String
        let counted: Bool
        let file: String
    }

    // MARK: Reading the sources

    /// Removes line and block comments, leaving string literals intact, so an example inside
    /// a doc comment is not collected as a key.
    private func stripComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\"" {
                let (literal, next) = readLiteral(text, from: index)
                out += literal == nil ? String(c) : String(text[index..<next])
                index = literal == nil ? text.index(after: index) : next
                continue
            }
            if text[index...].hasPrefix("//") {
                index = text[index...].firstIndex(of: "\n") ?? text.endIndex
                continue
            }
            if text[index...].hasPrefix("/*") {
                let after = text.index(index, offsetBy: 2)
                if let end = text.range(of: "*/", range: after..<text.endIndex) {
                    index = end.upperBound
                } else {
                    index = text.endIndex
                }
                continue
            }
            out.append(c)
            index = text.index(after: index)
        }
        return out
    }

    /// Reads one Swift string literal, returning its value and where it ended.
    private func readLiteral(_ text: String, from start: String.Index)
        -> (String?, String.Index) {
        guard text[start] == "\"" else { return (nil, start) }
        var value = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let c = text[index]
            if c == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return (nil, text.endIndex) }
                switch text[next] {
                case "n": value += "\n"
                case "t": value += "\t"
                case "\"": value += "\""
                case "\\": value += "\\"
                default: value += "\\" + String(text[next])   // `\(` and the rest
                }
                index = text.index(after: next)
                continue
            }
            if c == "\"" { return (value, text.index(after: index)) }
            value.append(c)
            index = text.index(after: index)
        }
        return (nil, text.endIndex)
    }

    /// Every key one file asks for, joining literals added together with `+` into one.
    private func asks(in source: String, file: String) -> [Ask] {
        let text = stripComments(source)
        var found: [Ask] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "(") else { break }
            defer { index = text.index(after: open) }

            // `t(` or `tn(`, and not the tail of a longer name.
            var counted = false
            var nameStart = open
            guard nameStart > text.startIndex else { continue }
            nameStart = text.index(before: nameStart)
            if text[nameStart] == "n" {
                guard nameStart > text.startIndex else { continue }
                nameStart = text.index(before: nameStart)
                counted = true
            }
            guard text[nameStart] == "t" else { continue }
            if nameStart > text.startIndex {
                let before = text[text.index(before: nameStart)]
                if before.isLetter || before.isNumber || before == "_" || before == "."
                    || before == "\"" { continue }
            }

            // The literals that follow, joined across `+`.
            var parts: [String] = []
            var cursor = text.index(after: open)
            while true {
                while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\n"
                    || text[cursor] == "\t" { cursor = text.index(after: cursor) }
                guard cursor < text.endIndex, text[cursor] == "\"" else { break }
                let (literal, next) = readLiteral(text, from: cursor)
                guard let literal else { break }
                parts.append(literal)
                cursor = next
                var peek = cursor
                while peek < text.endIndex, text[peek] == " " || text[peek] == "\n"
                    || text[peek] == "\t" { peek = text.index(after: peek) }
                guard peek < text.endIndex, text[peek] == "+" else { break }
                cursor = text.index(after: peek)
            }

            let key = parts.joined()
            guard !key.isEmpty, !key.contains("\\(") else { continue }
            found.append(Ask(key: key, counted: counted, file: file))
        }
        return found
    }

    private func everythingAsked() throws -> [Ask] {
        let root = StringTablesTests.sourcesDirectory
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
        var out: [Ask] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The tables hold keys and translations, not calls asking for one.
            guard url.lastPathComponent != "Strings.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            out += asks(in: text, file: url.lastPathComponent)
        }
        return out
    }

    // MARK: The scanner itself

    func testTheScannerReadsWhatTheScreensActuallyWrite() {
        let source = """
        // t("in a comment") is not a string to translate
        /* nor t("in a block") */
        let a = t("plain")
        let b = tn("%d file(s)", n)
        let c = t("a long one "
                + "written across lines")
        let d = t("with \\(interpolation) in it")
        let e = format(t("nested"))
        let f = subtract(x)
        """
        let found = asks(in: source, file: "sample.swift")
        XCTAssertEqual(found.map(\.key),
                       ["plain", "%d file(s)", "a long one written across lines", "nested"])
        XCTAssertEqual(found.map(\.counted), [false, true, false, false])
    }

    // MARK: The promise

    /// Guards the checks below, which pass equally when the scan reads no files at all.
    func testTheSourcesAreWhereThisThinksTheyAreAndThereAreALotOfThem() throws {
        let sources = StringTablesTests.sourcesDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.path), sources.path)
        let asked = try everythingAsked()
        XCTAssertGreaterThan(asked.count, 300,
                             "the interface asks for far more strings than this")
        XCTAssertGreaterThan(Set(asked.map(\.file)).count, 20, "across far more files")
    }

    func testEveryStringTheInterfaceAsksForHasARussianTranslation() throws {
        var missing: [Ask] = []

        for ask in try everythingAsked() {
            if ask.counted {
                let forms = Strings.plural(ask.key, in: .ru) ?? [:]
                // Russian needs all three of "one", "few" and "many".
                if forms["one"] == nil || forms["few"] == nil || forms["many"] == nil {
                    missing.append(ask)
                }
            } else if Strings.text(ask.key, in: .ru) == nil {
                missing.append(ask)
            }
        }

        XCTAssertTrue(missing.isEmpty,
                      "untranslated:\n"
                      + missing.map { "  \($0.file): \($0.key)" }.joined(separator: "\n"))
    }

    func testACountedStringCarriesBothEnglishFormsAsWell() throws {
        // English otherwise falls back to the key itself, which cannot inflect.
        var wrong: [String] = []
        for ask in try everythingAsked() where ask.counted {
            let forms = Strings.plural(ask.key, in: .en) ?? [:]
            if forms["one"] == nil || forms["other"] == nil { wrong.append(ask.key) }
        }
        XCTAssertTrue(wrong.isEmpty, "no English plural forms: \(wrong)")
    }

    func testTheKeysNothingCanScanForAreInTheTablesToo() {
        // Looked up through a variable, so the scanner cannot find them.
        let byHand = [
            "Local", "Russian", "English",                      // LabelLanguage
            "Standard (4 levels)", "Smooth (8 levels)",         // LevelsProfile
            "whatever the local mappers wrote — Russian in Russia, German in Germany",
            "mkgmap's default — smaller maps, coarser zoom steps",
            "Amenities", "Shops", "Tourism", "Road features"    // hideable categories
        ]
        for key in byHand {
            XCTAssertNotNil(Strings.text(key, in: .ru), "no translation for \"\(key)\"")
        }
    }
}
