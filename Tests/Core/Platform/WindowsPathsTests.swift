import XCTest

@testable import kmap

/// Spelling one path the other side's way, across the WSL boundary.
///
/// Only WSL needs this: a native Windows build has nothing to translate, and a Unix
/// without mounted drives never meets a drive letter.
final class WindowsPathsTests: XCTestCase {
    func testADriveLetterBecomesAMountPointAndBack() {
        XCTAssertEqual(
            Platform.defaultWindowsPath(for: "/mnt/e/Garmin/x.img"),
            #"E:\Garmin\x.img"#
        )
        XCTAssertEqual(Platform.linuxPath(for: #"E:\Garmin\x.img"#), "/mnt/e/Garmin/x.img")
    }

    func testTheDriveLetterIsUppercasedGoingOutAndLowercasedComingBack() {
        // Windows writes E:, and the mount point is /mnt/e.
        XCTAssertEqual(Platform.defaultWindowsPath(for: "/mnt/c/Users"), #"C:\Users"#)
        XCTAssertEqual(Platform.linuxPath(for: #"C:\Users"#), "/mnt/c/Users")
    }

    func testTheRootOfADriveHasNothingAfterTheBackslash() {
        XCTAssertEqual(Platform.defaultWindowsPath(for: "/mnt/e"), #"E:\"#)
        XCTAssertEqual(Platform.linuxPath(for: #"E:\"#), "/mnt/e/")
    }

    func testSpacesAndCyrillicSurviveBothDirections() {
        let linux = "/mnt/e/Garmin/Карты Региона/style.typ"
        let windows = #"E:\Garmin\Карты Региона\style.typ"#
        XCTAssertEqual(Platform.defaultWindowsPath(for: linux), windows)
        XCTAssertEqual(Platform.linuxPath(for: windows), linux)
    }

    func testSomewhereWindowsCannotReachHasNoWindowsPath() {
        XCTAssertNil(Platform.defaultWindowsPath(for: "/home/k/.kmap/work"))
        XCTAssertNil(Platform.defaultWindowsPath(for: "/mnt"))
        XCTAssertNil(
            Platform.defaultWindowsPath(for: "/mnt/wsl/instance"),
            "a multi-letter name under /mnt is not a drive"
        )
    }

    func testSomethingThatIsNotAWindowsPathHasNoLinuxPath() {
        XCTAssertNil(Platform.linuxPath(for: #"\\server\share\map.typ"#))
        XCTAssertNil(Platform.linuxPath(for: "Documents"))
        XCTAssertNil(Platform.linuxPath(for: ""))
        XCTAssertNil(Platform.linuxPath(for: "4:\\x"), "a digit is not a drive letter")
    }

    /// A pick inside the distribution's own files comes back as a share only wslpath knows.
    func testAPickInsideTheDistributionIsAskedOfWslpath() {
        let share = #"\\wsl.localhost\Ubuntu\home\u\maps"#
        XCTAssertEqual(
            Platform.linuxPath(
                fromWindows: share,
                which: { _ in "/usr/bin/wslpath" },
                runner: { _, arguments in
                    arguments == ["-u", share] ? "/home/u/maps\n" : nil
                }
            ),
            "/home/u/maps"
        )
        // Without it the drive letters still work, and a share does not.
        XCTAssertEqual(Platform.linuxPath(fromWindows: #"E:\x"#, which: { _ in nil }), "/mnt/e/x")
        XCTAssertNil(Platform.linuxPath(fromWindows: share, which: { _ in nil }))
        // An error from wslpath is not a path.
        XCTAssertEqual(
            Platform.linuxPath(
                fromWindows: #"E:\x"#,
                which: { _ in "/usr/bin/wslpath" },
                runner: { _, _ in "wslpath: E:\\x: Invalid argument" }
            ),
            "/mnt/e/x"
        )
    }
}
