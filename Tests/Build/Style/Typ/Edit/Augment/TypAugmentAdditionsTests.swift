import XCTest

@testable import kmap

/// The sections a build's copy gains.
final class TypAugmentAdditionsTests: XCTestCase {
    private let mark = TypAugment.sections(of: StyleAssets.repairMarks)[0]

    func testOnlyAWantedMarkIsAdded() {
        XCTAssertTrue(TypAugment.additions(wanted: [], moved: [:], copies: [], byteForByte: false).isEmpty)
        let added = TypAugment.additions(
            wanted: [(.line, mark.code, "a mark")],
            moved: [:],
            copies: [(0x99, "[_line]\nType=0x99\n[end]")],
            byteForByte: false
        )
        XCTAssertEqual(added.map(\.code), [mark.code, 0x99])
    }

    func testAMovedMarkWearsItsNewNumber() {
        let added = TypAugment.additions(
            wanted: [(.line, 0x7e, "a mark")],
            moved: [.line: [mark.code: 0x7e]],
            copies: [],
            byteForByte: false
        )
        XCTAssertEqual(added.map(\.code), [0x7e])
        XCTAssertTrue(added[0].text.contains("Type=0x7e"), added[0].text)
    }

    /// A page kept byte for byte cannot carry Cyrillic: the label line goes, the rest stays.
    func testAPageKeptByteForByteLosesOnlyTheLinesItCannotHold() {
        let added = TypAugment.additions(
            wanted: [],
            moved: [:],
            copies: [(0x99, "Type=0x99\nString=0x19,Тропа\n[end]")],
            byteForByte: true
        )
        XCTAssertEqual(added[0].text, "Type=0x99\n[end]")
    }
}
