import XCTest

@testable import kmap

/// The build's copy is written beside the build, never over the file it was made from.
final class TypAugmentWriteTests: XCTestCase {
    private func folder() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("write-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        Paths.ensure(url)
        return url
    }

    func testTheCopyIsWrittenBesideTheBuild() throws {
        let own = folder(), build = folder()
        let typ = own.appendingPathComponent("style.txt")
        let result = TypAugment.Copy(Data("[_id]\n[end]\n".utf8)).written(from: typ, into: build)
        XCTAssertEqual(result.url, build.appendingPathComponent("style.txt"))
        XCTAssertTrue(FileTools.exists(result.url))
        XCTAssertEqual(result.added, [], "nothing was appended, so nothing was added")
        XCTAssertNil(result.refusal)
    }

    func testTheOriginalIsNeverWrittenOver() throws {
        let own = folder()
        let typ = own.appendingPathComponent("style.txt")
        try FileTools.write("[_id]\n[end]\n", to: typ)
        let result = TypAugment.Copy(Data("changed\n".utf8)).written(from: typ, into: own)
        XCTAssertEqual(result.url, typ)
        XCTAssertNotNil(result.refusal)
        XCTAssertEqual(try String(contentsOf: typ, encoding: .utf8), "[_id]\n[end]\n")
    }
}
