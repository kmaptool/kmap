import XCTest

@testable import kmap

/// The build's copy of a TYP, worked on step by step.
final class TypAugmentCopyTests: XCTestCase {
    private func copy(_ text: String) -> TypAugment.Copy { TypAugment.Copy(Data(text.utf8)) }

    /// Read in LF alone, whatever the file's line ends.
    func testTheCopyReadsInLineFeedsAlone() {
        let made = copy("[_id]\r\nFID=1\r\n[end]\r\n")
        XCTAssertEqual(made.original, "[_id]\nFID=1\n[end]\n")
        XCTAssertFalse(made.byteForByte)
        XCTAssertTrue(made.readsAlike, "pure ASCII reads alike")
    }

    /// kmap's sections go at the end, under a note saying whose they are.
    func testTheSectionsGoAtTheEndUnderANote() {
        var made = copy("[_id]\nFID=1\n[end]")
        made.append([(0x99, "[_line]\nType=0x99\n[end]")], from: URL(fileURLWithPath: "/x/style.txt"), theme: .all)
        XCTAssertTrue(made.addedAny)
        XCTAssertTrue(made.text.hasPrefix("[_id]\nFID=1\n[end]\n"), made.text)
        XCTAssertTrue(made.text.contains("; Added by kmap for this build. Not part of style.txt;"), made.text)
        XCTAssertTrue(made.text.hasSuffix("[_line]\nType=0x99\n[end]\n"), made.text)
    }

    func testNothingToAppendLeavesTheTextAlone() {
        var made = copy("[_id]\n[end]\n")
        let before = made.text
        made.append([], from: URL(fileURLWithPath: "/x/style.txt"), theme: .all)
        XCTAssertFalse(made.addedAny)
        XCTAssertEqual(made.text, before)
    }
}
