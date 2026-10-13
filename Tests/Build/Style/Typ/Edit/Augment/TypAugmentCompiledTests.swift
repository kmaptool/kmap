import XCTest

@testable import kmap

/// A compiled TYP goes to the build as a copy beside it, with the reason nothing was added.
final class TypAugmentCompiledTests: XCTestCase {
    func testACompiledTypIsCopiedBesideTheBuildAndSaysWhy() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compiled-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let own = folder.appendingPathComponent("mine", isDirectory: true)
        let build = folder.appendingPathComponent("build", isDirectory: true)
        Paths.ensure(own)
        let typ = own.appendingPathComponent("style.typ")
        try FileTools.write(Data([1, 2, 3]), to: typ)

        let result = TypAugment.compiledCopy(typ, theme: .day, into: build)

        XCTAssertEqual(result.url, build.appendingPathComponent("style.typ"))
        XCTAssertEqual(try Data(contentsOf: result.url), Data([1, 2, 3]))
        XCTAssertTrue(result.refusal?.contains("drop its night colours") == true, result.refusal ?? "")
        XCTAssertEqual(result.added, [])
    }
}
