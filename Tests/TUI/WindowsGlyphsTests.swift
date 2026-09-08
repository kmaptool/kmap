import XCTest
@testable import kmap

/// Whether every glyph the interface draws is one a Windows console can show.
///
/// Consolas and Cascadia stop at WGL4. A character outside it comes out as a hollow box,
/// and the tick, the spinner and the Enter key all died that way in a Windows build
/// before anyone noticed — so the check belongs here rather than in a screenshot.
final class WindowsGlyphsTests: XCTestCase {

    /// Characters a WGL4 font carries, beyond ASCII and Cyrillic.
    private let safe = Set("·×÷°±–—…‹›«»•¶§©®™µ¹²³¼½¾¿¡√∞≈≡≤≥−∙¬←↑→↓↔↕↨▀▄█▌▐░▒▓"
                           + "─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬►◄")

    private func sources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/kmap")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path),
                          "not a working copy")
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (all?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testEveryGlyphTheInterfaceDrawsSurvivesAWindowsConsole() throws {
        var homeless: [Character: String] = [:]
        for file in try sources() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\n") {
                // Only what could reach the screen: the literals.
                for part in line.components(separatedBy: "\"").enumerated()
                where part.offset % 2 == 1 {
                    for ch in part.element {
                        guard let scalar = ch.unicodeScalars.first, scalar.value > 0x7F,
                              !(0x400...0x4FF).contains(scalar.value),
                              !ch.isLetter, !safe.contains(ch),
                              Glyph.windowsSubstitutes[ch] == nil else { continue }
                        homeless[ch] = file.lastPathComponent
                    }
                }
            }
        }
        XCTAssertTrue(homeless.isEmpty,
                      "no Windows substitute for: "
                      + homeless.map { "\($0.key) U+\(String(format: "%04X", $0.key.unicodeScalars.first!.value)) in \($0.value)" }
                          .sorted().joined(separator: ", "))
    }

    /// A substitute only helps where the text passes through `Surface`, which draws every
    /// cell through `Glyph.drawable`. What the command line prints goes straight out, so
    /// there the substitution has to be made where the character is written.
    func testWhatIsPrintedRatherThanDrawnIsSubstitutedWhereItIsWritten() throws {
        var raw: [String] = []
        for file in try sources() where file.path.contains("/CLI/") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                guard !line.contains("Glyph.drawable") else { continue }
                for part in line.components(separatedBy: "\"").enumerated()
                where part.offset % 2 == 1 {
                    for ch in part.element where Glyph.windowsSubstitutes[ch] != nil {
                        raw.append("\(ch) in \(file.lastPathComponent):\(number + 1)")
                    }
                }
            }
        }
        XCTAssertTrue(raw.isEmpty, "printed without a Windows substitute: "
                      + raw.sorted().joined(separator: ", "))
    }

    /// A key name inside a sentence is spelled out rather than swapped for one character:
    /// "press ← to build" is not what the line meant to say.
    func testAKeyNameInASentenceIsSpelledOut() {
        XCTAssertEqual(L10n.keyNames(in: "press ⏎ to build"), "press Enter to build")
        XCTAssertEqual(L10n.keyNames(in: "press ⇥ to type it instead"),
                       "press Tab to type it instead")
        XCTAssertEqual(L10n.keyNames(in: "nothing to undo"), "nothing to undo")
    }

    /// Every frame a Windows console turns through has to be its own: the ten braille
    /// frames map onto four strokes, and drawing those ten sent the wheel back a step at
    /// the end of each cycle.
    func testTheWindowsSpinnerTurnsWithoutRepeatingAFrame() {
        let drawn = Glyph.windowsSpinner.map { Glyph.windowsSubstitutes[$0] ?? $0 }
        XCTAssertEqual(Set(drawn).count, drawn.count, "\(drawn) draws the same frame twice")
    }

    func testTheSubstitutesAreThemselvesDrawable() {
        for (_, to) in Glyph.windowsSubstitutes {
            XCTAssertTrue(to.isASCII || safe.contains(to), "\(to) is no better than what it replaces")
        }
    }
}
