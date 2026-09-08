import XCTest
@testable import kmap

/// Which of the four machines this is.
///
/// Detection answers from the compiler, so each platform can only check its own case.
/// Everything the answer decides is passed a platform instead and is tested anywhere.
final class PlatformTests: XCTestCase {

    #if !canImport(Darwin) && !os(Windows)
    func testTheVariableWslSetsForEveryShellIsEnough() {
        XCTAssertEqual(Platform.detect(environment: ["WSL_DISTRO_NAME": "Ubuntu"],
                                       osRelease: nil), .wsl)
        XCTAssertEqual(Platform.detect(environment: ["WSL_INTEROP": "/run/WSL/8_interop"],
                                       osRelease: nil), .wsl)
    }

    func testAKernelBuiltByMicrosoftSaysSoEvenWithNoVariablesSet() {
        // A process started outside a login shell has none of the variables set.
        XCTAssertEqual(Platform.detect(environment: [:],
                                       osRelease: "5.15.146.1-microsoft-standard-WSL2"), .wsl)
    }

    func testAnOrdinaryLinuxIsOrdinaryLinux() {
        XCTAssertEqual(Platform.detect(environment: [:],
                                       osRelease: "6.8.0-45-generic"), .linux)
        XCTAssertEqual(Platform.detect(environment: [:], osRelease: nil), .linux)
    }
    #endif

    #if canImport(Darwin)
    func testAMacIsAMacWhateverTheEnvironmentSays() {
        XCTAssertEqual(Platform.detect(environment: ["WSL_DISTRO_NAME": "Ubuntu"],
                                       osRelease: "microsoft"), .macOS)
    }
    #endif

    #if os(Windows)
    func testWindowsIsWindowsAndNotTheLinuxThatMightBeUnderIt() {
        // `cmd.exe` started from a WSL session inherits WSL's variables and is still
        // Windows.
        XCTAssertEqual(Platform.detect(environment: ["WSL_DISTRO_NAME": "Ubuntu"],
                                       osRelease: "microsoft"), .windows)
    }
    #endif

    func testOnlyWindowsSpellsPathsTheWindowsWay() {
        // Under WSL the desktop is Windows, but the paths this process opens are
        // Linux's.
        XCTAssertTrue(Platform.windows.usesWindowsPaths)
        XCTAssertFalse(Platform.wsl.usesWindowsPaths)
        XCTAssertFalse(Platform.linux.usesWindowsPaths)
        XCTAssertFalse(Platform.macOS.usesWindowsPaths)
        XCTAssertTrue(Platform.wsl.isWSL)
        XCTAssertFalse(Platform.windows.isWSL)
    }
}
