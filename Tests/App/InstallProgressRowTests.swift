import XCTest
@testable import kmap

/// The two lines an install is drawn as, on either screen.
final class InstallProgressRowTests: XCTestCase {

    func testBeforeAnyStageTheLineSaysItIsStarting() {
        let progress = InstallProgress()
        progress.begin("java")
        XCTAssertEqual(InstallProgressRow.status(progress), t("starting"))
    }

    func testAStepIsItsOwnLine() {
        let progress = InstallProgress()
        progress.step("unpacking")
        XCTAssertEqual(InstallProgressRow.status(progress), "unpacking")
        XCTAssertNil(progress.fraction, "no number to draw a bar from")
    }

    func testADownloadAddsTheBytes() {
        let progress = InstallProgress()
        let download = DownloadProgress()
        download.begin(total: 2000, partTotals: [2000], alreadyOnDisk: 0)
        download.advance(part: 0, by: 960)
        progress.downloading("downloading", download)
        let line = InstallProgressRow.status(progress)
        XCTAssertTrue(line.hasPrefix("downloading"))
        XCTAssertTrue(line.contains("960 B / 2 kB"), line)
        XCTAssertEqual(progress.fraction, 0.48)
    }

    func testTheBarIsDrawnUnderTheLine() {
        let progress = InstallProgress()
        let download = DownloadProgress()
        download.begin(total: 2000, partTotals: [2000], alreadyOnDisk: 0)
        download.advance(part: 0, by: 960)
        progress.downloading("downloading", download)

        let surface = Surface()
        surface.resize(60, 3)
        surface.clear(Theme.strict.base)
        InstallProgressRow.draw(surface, x: 0, y: 0, width: 60, progress: progress,
                                theme: .strict)
        // The frame is one ANSI string; the rows are addressed, not separated.
        let drawn = surface.compose()
        XCTAssertTrue(drawn.contains("downloading"))
        XCTAssertTrue(drawn.contains("48%"))
        XCTAssertTrue(drawn.contains(String(Glyph.drawable(Glyph.barFill))))
        XCTAssertTrue(drawn.contains("\u{1B}[2;1H"), "the bar is on the second row")
    }
}
