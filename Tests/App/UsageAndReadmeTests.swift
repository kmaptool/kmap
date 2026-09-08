import XCTest
@testable import kmap

/// Holds `kmap --help` and the README to the same set of commands and flags: neither may
/// omit what the other names, and the README may name nothing the usage does not.
final class UsageAndReadmeTests: XCTestCase {

    private func readme(_ name: String = "README.md") throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository
        let url = root.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "not a working copy")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `--flag` the usage names, as the usage writes it.
    private var usageFlags: Set<String> {
        var found: Set<String> = []
        for line in CLI.usage.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--") else { continue }
            // The usage sets the description off with two spaces; one line can name a
            // flag and its negative, as in `--dem, --no-dem`.
            let head = trimmed.components(separatedBy: "  ")[0]
            for word in head.split(whereSeparator: { $0 == "," || $0 == " " }) {
                let name = word.split(separator: "=")[0]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if name.hasPrefix("--") { found.insert(name) }
            }
        }
        return found
    }

    /// Every `kmap <command>` the usage names.
    private var usageCommands: Set<String> {
        var found: Set<String> = []
        for line in CLI.usage.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("kmap ") else { continue }
            // `kmap` alone is padded out to the description column; a command follows
            // the program name after a single space.
            let rest = trimmed.dropFirst("kmap ".count)
            guard let first = rest.first, first != " ", first.isLetter || first == "-" else {
                continue
            }
            let name = String(rest.split(separator: " ")[0])
            found.insert(name)
        }
        return found
    }

    func testTheUsageNamesEveryCommandTheCLIAnswersTo() {
        // The set comes from the usage text; the dispatch switch cannot be read at
        // runtime.
        XCTAssertTrue(usageCommands.contains("build"))
        XCTAssertTrue(usageCommands.contains("verify"))
        XCTAssertGreaterThan(usageCommands.count, 15,
                             "the usage used to list six of twenty-two commands")
    }

    func testTheReadmeDocumentsEveryBuildFlag() throws {
        let text = try readme()
        let missing = usageFlags.filter { !text.contains($0) }.sorted()
        XCTAssertTrue(missing.isEmpty,
                      "not in README.md: " + missing.joined(separator: ", "))
    }

    /// The two READMEs are one document in two languages: a command or a flag named in
    /// one and missing from the other is a translation that fell behind.
    func testTheRussianReadmeSaysTheSameAsTheEnglishOne() throws {
        let english = try readme()
        let russian = try readme("README.ru.md")
        let commands = usageCommands.filter { english.contains("kmap \($0)") }
        XCTAssertTrue(commands.allSatisfy { russian.contains("kmap \($0)") },
                      "not in README.ru.md: "
                      + commands.filter { !russian.contains("kmap \($0)") }
                          .sorted().joined(separator: ", "))
        let flags = usageFlags.filter { english.contains($0) }
        XCTAssertTrue(flags.allSatisfy { russian.contains($0) },
                      "not in README.ru.md: "
                      + flags.filter { !russian.contains($0) }
                          .sorted().joined(separator: ", "))
    }

    func testTheReadmeDocumentsEveryCommand() throws {
        let text = try readme()
        let missing = usageCommands.filter { !text.contains("kmap \($0)") }.sorted()
        XCTAssertTrue(missing.isEmpty,
                      "not in README.md: " + missing.joined(separator: ", "))
    }

    /// Fails when the README documents a flag the usage does not name.
    func testTheReadmeInventsNothing() throws {
        let text = try readme()
        var claimed: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("| `--") {
            for word in line.split(separator: "`") where word.hasPrefix("--") {
                for name in word.split(separator: ",") {
                    let flag = name.split(separator: "=")[0]
                        .split(separator: "\\")[0]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ,`"))
                    if flag.hasPrefix("--") { claimed.insert(flag) }
                }
            }
        }
        let invented = claimed.filter { !usageFlags.contains($0) }.sorted()
        XCTAssertTrue(invented.isEmpty,
                      "README names flags the program does not: " + invented.joined(separator: ", "))
    }
}
