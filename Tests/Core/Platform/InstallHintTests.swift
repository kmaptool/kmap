import XCTest
@testable import kmap

/// The line kmap prints when it cannot install something itself.
///
/// The command named is the one that machine's own package manager understands.
final class InstallHintTests: XCTestCase {

    func testTheInstallAdviceNamesTheManagerThisMachineActuallyHas() {
        XCTAssertEqual(Platform.installHint(.java, manager: .homebrew, privilege: .direct),
                       "brew install openjdk")
        XCTAssertEqual(Platform.installHint(.java, manager: .apt, privilege: .wouldAsk),
                       "sudo apt install -y --no-install-recommends default-jdk")
        XCTAssertEqual(Platform.installHint(.java, manager: .pacman, privilege: .wouldAsk),
                       "sudo pacman -S --needed --noconfirm jdk-openjdk")
        XCTAssertFalse(Platform.installHint(.python, manager: .apt, privilege: .wouldAsk)
                           .contains("brew"))
    }

    func testWindowsAdviceIsAWingetLineWithNoSudoInFrontOfIt() {
        let hint = Platform.installHint(.java, manager: .winget, privilege: .direct)
        XCTAssertTrue(hint.hasPrefix("winget install"), hint)
        XCTAssertTrue(hint.contains("Microsoft.OpenJDK.21"), hint)
        // There is no sudo on Windows.
        XCTAssertFalse(hint.contains("sudo"), hint)
    }

    func testAMachineWithNoManagerAtAllIsSentSomewhereItCanActuallyGetIt() {
        // With no manager to name, an address to download from is what is left.
        let hint = Platform.installHint(.java, manager: nil)
        XCTAssertFalse(hint.contains("apt"))
        XCTAssertFalse(hint.contains("brew"))
        XCTAssertTrue(hint.contains("adoptium.net"), hint)
    }

    func testAManagerThatDoesNotCarryItIsTheSameAsNoManager() {
        // winget names no unzip, since Windows opens a zip itself; what is left is a
        // sentence rather than a command that would fail.
        let hint = Platform.installHint(.unzip, manager: .winget, privilege: .direct)
        XCTAssertFalse(hint.contains("winget"), hint)
    }

    func testEveryNeedIsEitherInstallableOrHasAnAddress() {
        // unzip is the exception: every supported machine can already open a zip.
        for need in [PackageManager.Need.java, .python] {
            XCTAssertNotNil(need.homepage, "\(need)")
        }
        XCTAssertNil(PackageManager.Need.unzip.homepage)
    }
}
