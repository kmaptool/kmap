import XCTest
@testable import kmap

/// A path spelled the way the machine's own programs read it.
///
/// The accessor differs from `URL.path` on exactly one platform: on the Unixes it must
/// be `.path` byte for byte, and on Windows the same path with native separators.
final class NativePathTests: XCTestCase {

    /// `/home/user/x` on the Unixes, `\home\k\x` on Windows: the same path, spelled twice.
    private func native(_ posix: String) -> String {
        #if os(Windows)
        return posix.replacingOccurrences(of: "/", with: #"\"#)
        #else
        return posix
        #endif
    }

    func testAnOrdinaryPathIsUnchanged() {
        let url = URL(fileURLWithPath: "/home/user/Garmin/kmap/region-a.img")
        XCTAssertEqual(url.nativePath, native("/home/user/Garmin/kmap/region-a.img"))
    }

    func testCyrillicAndSpacesArriveByteForByte() {
        let path = "/home/user/Garmin/Карты Региона/style.typ"
        XCTAssertEqual(URL(fileURLWithPath: path).nativePath, native(path))
    }

    func testADirectoryDoesNotGrowATrailingSeparator() {
        let url = URL(fileURLWithPath: "/home/user/.kmap/work", isDirectory: true)
        XCTAssertEqual(url.nativePath, native("/home/user/.kmap/work"))
    }

    func testEveryNameKmapMeetsSurvivesTheJourney() {
        for path in ["/tmp/x", "/tmp/with space/x.img", "/tmp/ü/ß/x",
                     "/tmp/日本語/x.typ", "/tmp/a.b.c/d"] {
            XCTAssertEqual(URL(fileURLWithPath: path).nativePath, native(path), path)
        }
    }

    #if !os(Windows)
    func testItIsWhatPathAlwaysSaidHereAndNothingNew() {
        // On the Unixes the accessor must not change a single answer.
        for path in ["/", "/tmp/x", "/tmp/with space/x.img", "/tmp/日本語/x.typ"] {
            XCTAssertEqual(URL(fileURLWithPath: path).nativePath,
                           URL(fileURLWithPath: path).path, path)
        }
    }
    #endif

    #if os(Windows)
    func testWhatPathActuallySaysHereSoTheDifferenceIsOnRecord() {
        // Recorded because `URL.path` here is not what a Unix reading of the name says.
        let url = URL(fileURLWithPath: #"C:\Users\k\AppData\Local\kmap"#)
        print("URL.path is: \(url.path)")
        print("URL.nativePath is: \(url.nativePath)")
        XCTAssertTrue(url.nativePath.hasPrefix("C:"), url.nativePath)
    }

    func testWindowsGetsBackslashesWhereTheUrlWouldHaveGivenSlashes() {
        // `URL.path` gives the POSIX-shaped path inside the URL — `/E:/Garmin/x.img` —
        // which no Windows program can open.
        let url = URL(fileURLWithPath: #"E:\Garmin\x.img"#)
        XCTAssertEqual(url.nativePath, #"E:\Garmin\x.img"#)
        XCTAssertNotEqual(url.nativePath, url.path)
    }
    #endif
}
