import XCTest

@testable import kmap

/// 2 maps compared tag by tag by what each shows: a picture, nothing, or the
/// receiver's own drawing of a number the style has no section for.
final class CLITagComparisonTests: XCTestCase {
    private let tag = "waterway=stream"

    private func fill(_ kind: String, _ code: Int, _ colour: String) -> String {
        "[_\(kind)]\nType=\(TypeMeaning.hex(code))\nXpm=\"0 0 1 0\"\n\"! c #\(colour)\"\n[end]\n"
    }

    private func clearLine(_ code: Int) -> String {
        TypAugment.nothing(code: code, labels: []).joined(separator: "\n") + "\n"
    }

    private func clearArea(_ code: Int) -> String {
        let rows = Array(repeating: "\"" + String(repeating: "a", count: 32) + "\"", count: 32)
        return
            (["[_polygon]", "Type=" + TypeMeaning.hex(code), "Xpm=\"32 32 2 1\"", "\"a c none\"", "\"b c #000000\""]
            + rows + ["[end]"]).joined(separator: "\n") + "\n"
    }

    private func report(_ codes: [String: Int], ground: Int = 8) -> StyleRecovery.Report {
        var report = StyleRecovery.Report()
        if !codes.isEmpty { report.codesByTag = [tag: codes] }
        report.groundTags = [tag: ground]
        return report
    }

    private func compare(
        theirs: [String: Int],
        ours: [String: Int],
        theirTyp: String?,
        ourTyp: String?,
        ground: Int = 8
    ) -> (same: Int, different: [String], missing: Int) {
        let compared = CLI.TagComparison(
            original: report(theirs),
            rebuilt: report(ours, ground: ground),
            theirTyp: theirTyp.map { TypSource.parse($0) },
            ourTyp: ourTyp.map { TypSource.parse($0) }
        )
        return (compared.same, compared.different.map { $0.theirs + " / " + $0.ours }, compared.missing.count)
    }

    func testTheSamePictureOnDifferentNumbersAgrees() {
        let seen = compare(
            theirs: ["L18": 8],
            ours: ["L26": 8],
            theirTyp: fill("line", 0x18, "0000ff"),
            ourTyp: fill("line", 0x26, "0000ff")
        )
        XCTAssertEqual(seen.same, 1)
        XCTAssertTrue(seen.different.isEmpty)
    }

    func testADifferentPictureDiffers() {
        let seen = compare(
            theirs: ["L18": 8],
            ours: ["L18": 8],
            theirTyp: fill("line", 0x18, "0000ff"),
            ourTyp: fill("line", 0x18, "00ff00")
        )
        XCTAssertEqual(seen.different, ["L18 / L18"])
    }

    /// Neither map shows the tag: a clear section there, no element here.
    func testClearThereAndLeftOutHereAgrees() {
        let seen = compare(theirs: ["L18": 8], ours: [:], theirTyp: clearLine(0x18), ourTyp: "")
        XCTAssertEqual(seen.same, 1)
        XCTAssertEqual(seen.missing, 0)
        let area = compare(theirs: ["A23": 8], ours: [:], theirTyp: clearArea(0x23), ourTyp: "")
        XCTAssertEqual(area.same, 1)
    }

    func testClearOnBothSidesAgreesWhateverTheNumbers() {
        let seen = compare(theirs: ["L18": 8], ours: ["L26": 8], theirTyp: clearLine(0x18), ourTyp: clearLine(0x26))
        XCTAssertEqual(seen.same, 1)
    }

    /// A number with no section is drawn by the receiver: not the nothing a clear
    /// section shows, even on the same number.
    func testClearAgainstANumberLeftToTheReceiverDiffers() {
        let hidden = compare(theirs: ["L0a": 8], ours: ["L0a": 8], theirTyp: clearLine(0x0a), ourTyp: "")
        XCTAssertEqual(hidden.different, ["L0a (clear) / L0a (unpainted)"])
        let shown = compare(theirs: ["L0a": 8], ours: ["L0a": 8], theirTyp: "", ourTyp: clearLine(0x0a))
        XCTAssertEqual(shown.different, ["L0a (unpainted) / L0a (clear)"])
    }

    func testANumberLeftToTheReceiverOnBothSidesAgreesByNumber() {
        XCTAssertEqual(compare(theirs: ["L06": 8], ours: ["L06": 8], theirTyp: "", ourTyp: "").same, 1)
        let other = compare(theirs: ["L06": 8], ours: ["L10": 8], theirTyp: "", ourTyp: "")
        XCTAssertEqual(other.different, ["L06 (unpainted) / L10 (unpainted)"])
    }

    func testAPictureThereAndNothingHereIsMissing() {
        let painted = compare(theirs: ["L18": 8], ours: [:], theirTyp: fill("line", 0x18, "0000ff"), ourTyp: "")
        XCTAssertEqual(painted.missing, 1)
        // The receiver draws it on their map: left out here, it is missing too.
        XCTAssertEqual(compare(theirs: ["L18": 8], ours: [:], theirTyp: "", ourTyp: "").missing, 1)
        // Clear and receiver-drawn among their codes: something is seen there.
        let mixed = compare(theirs: ["L18": 5, "L26": 4], ours: [:], theirTyp: clearLine(0x26), ourTyp: "")
        XCTAssertEqual(mixed.missing, 1)
        XCTAssertEqual(mixed.same, 0)
    }

    /// A blank icon still writes the name: a look of its own.
    func testABlankIconThereAndNothingHereIsMissing() {
        let blank = "[_point]\nType=0x6503\nDayXpm=\"1 1 1 1\"\n\"! c none\"\n\"!\"\n[end]\n"
        XCTAssertEqual(compare(theirs: ["P6503": 8], ours: [:], theirTyp: blank, ourTyp: "").missing, 1)
    }

    func testClearAgainstAPictureDiffers() {
        let seen = compare(
            theirs: ["L18": 8],
            ours: ["L18": 8],
            theirTyp: clearLine(0x18),
            ourTyp: fill("line", 0x18, "0000ff")
        )
        XCTAssertEqual(seen.different, ["L18 (clear) / L18"])
    }

    /// A style with a draw order shows no area it leaves out of it, painted or not.
    func testAnAreaMissingFromTheDrawOrderShowsNothing() {
        let order = "[_drawOrder]\nType=0x050,1\n[end]\n"
        let theirs = order + fill("polygon", 0x50, "60b020") + fill("polygon", 0x23, "ff0000")
        let unlisted = compare(theirs: ["A23": 8], ours: ["A23": 8], theirTyp: theirs, ourTyp: order)
        XCTAssertEqual(unlisted.same, 1)
        let listed = compare(theirs: ["A50": 8], ours: ["A50": 8], theirTyp: theirs, ourTyp: order)
        XCTAssertEqual(listed.different, ["A50 / A50 (unpainted)"])
    }

    /// 2 maps over 2 grounds share styles, not objects.
    func testATagTheRebuiltGroundDoesNotCarryIsNotCompared() {
        for typ in [fill("line", 0x18, "0000ff"), clearLine(0x18)] {
            let seen = compare(theirs: ["L18": 8], ours: [:], theirTyp: typ, ourTyp: "", ground: 0)
            XCTAssertEqual(seen.same, 0)
            XCTAssertEqual(seen.missing, 0)
        }
    }

    func testWithoutATypOnOneSideTheNumbersDecide() {
        XCTAssertEqual(compare(theirs: ["L18": 8], ours: ["L18": 8], theirTyp: clearLine(0x18), ourTyp: nil).same, 1)
        let other = compare(theirs: ["L18": 8], ours: ["L26": 8], theirTyp: nil, ourTyp: clearLine(0x26))
        XCTAssertEqual(other.different, ["L18 / L26"])
    }

    func testATagSeenTooLittleIsNotCompared() {
        let seen = compare(theirs: ["L18": 5], ours: [:], theirTyp: fill("line", 0x18, "0000ff"), ourTyp: "")
        XCTAssertEqual(seen.missing, 0)
    }
}
