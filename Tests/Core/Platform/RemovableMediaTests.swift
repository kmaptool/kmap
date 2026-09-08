import XCTest
@testable import kmap

/// Where a plugged-in device turns up, per platform.
final class RemovableMediaTests: XCTestCase {

    func testAMacLooksInTheOnePlaceAMacPutsThem() {
        XCTAssertEqual(Platform.mediaRoots(.macOS, environment: [:]), ["/Volumes"])
    }

    func testLinuxLooksWhereEachKindOfDesktopMountsThings() {
        let roots = Platform.mediaRoots(.linux, environment: ["USER": "user"])
        XCTAssertEqual(roots.first, "/media/user", "udisks2 on a desktop")
        XCTAssertTrue(roots.contains("/run/media/user"), "systemd-based distributions")
        XCTAssertTrue(roots.contains("/media"))
        XCTAssertTrue(roots.contains("/mnt"), "and wherever somebody mounted it by hand")
    }

    func testWslLooksAtTheWindowsDrivesBecauseThatIsWhereTheDeviceIs() {
        // Windows mounts the device as E:, and that is /mnt/e from in here.
        XCTAssertTrue(Platform.mediaRoots(.wsl, environment: [:]).contains("/mnt"))
    }

    func testEveryMountedVolumeIsOfferedOnceAndHiddenOnesAreNot() {
        let volumes = Platform.mountedVolumes(.wsl, environment: [:], contents: { root in
            root == "/mnt" ? ["c", "e", ".hidden", "wsl"] : []
        })
        XCTAssertEqual(volumes.map(\.path), ["/mnt/c", "/mnt/e", "/mnt/wsl"])
    }

    func testTheSameDirectoryReachedTwiceIsOfferedOnce() {
        // /media and /media/<user> overlap on some desktops.
        let volumes = Platform.mountedVolumes(.linux, environment: ["USER": "k"], contents: { root in
            root == "/media/k" || root == "/media" ? ["GARMIN"] : []
        })
        XCTAssertEqual(volumes.map(\.path), ["/media/k/GARMIN", "/media/GARMIN"])
    }

    // MARK: Windows has no directory of volumes, it has letters

    func testWindowsOffersTheDriveLettersThatAnswerAndNoOthers() {
        let drives = Platform.windowsDriveRoots(exists: { $0 == #"C:\"# || $0 == #"E:\"# })
        XCTAssertEqual(drives, [#"C:\"#, #"E:\"#])
    }

    func testTheFloppyLettersAreNotAsked() {
        // Asking about an empty A: raises the "insert a disk" dialog.
        var asked: [String] = []
        _ = Platform.windowsDriveRoots(exists: { asked.append($0); return false })
        XCTAssertFalse(asked.contains(#"A:\"#))
        XCTAssertFalse(asked.contains(#"B:\"#))
        XCTAssertEqual(asked.count, 24, "C through Z")
    }

    func testWindowsListsNoRootsBecauseThereIsNothingToListTheContentsOf() {
        XCTAssertEqual(Platform.mediaRoots(.windows, environment: [:]), [])
        // What is checked is the routing: the drive letters were asked and the directory
        // listing was not.
        let volumes = Platform.mountedVolumes(.windows, environment: [:],
                                              contents: { _ in
                                                  XCTFail("nothing to enumerate on Windows")
                                                  return []
                                              },
                                              exists: { $0 == #"E:\"# })
        XCTAssertEqual(volumes.count, 1)
    }
}
