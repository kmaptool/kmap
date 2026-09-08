import XCTest
@testable import kmap

/// A screen that binds letter commands normalizes the key through `key.command` or
/// `Keys.latin`, so the binding answers on a non-Latin keyboard layout as well.
final class CommandKeysTests: XCTestCase {

    func testEveryScreenWithLetterCommandsReadsThemThroughTheLayoutMap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/kmap/App")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: nil))
        var forgot: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let bindsLetters = text.range(of: #"case \.char\("[a-z]"\)"#,
                                          options: .regularExpression) != nil
            guard bindsLetters else { continue }
            if !text.contains("Keys.latin(") && !text.contains(".command") {
                forgot.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(forgot.isEmpty, "letter commands read raw: \(forgot.joined(separator: ", "))")
    }
}
