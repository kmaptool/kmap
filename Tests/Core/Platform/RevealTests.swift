import XCTest
@testable import kmap

/// Revealing a finished map in the platform's own file manager.
///
/// Four platforms, three answers: select the file (macOS, Windows, and WSL through
/// Windows), or open the containing folder (Linux, where `xdg-open` cannot select).
final class RevealTests: XCTestCase {

    private let mapFile = URL(fileURLWithPath: "/home/k/Garmin/kmap/2026-08-27/region-a.img")

    func testAMacSelectsTheFileInsideItsFolder() {
        let command = Platform.revealCommand(for: mapFile, on: .macOS,
                                             which: { "/usr/bin/" + $0 })
        XCTAssertEqual(command?.executable, "/usr/bin/open")
        XCTAssertEqual(command?.arguments, ["-R", mapFile.path])
    }

    func testLinuxOpensTheFolderBecauseXdgOpenCannotSelectAnything() {
        // Handed the file, xdg-open would launch whatever application claims .img.
        let command = Platform.revealCommand(for: mapFile, on: .linux,
                                             which: { $0 == "xdg-open" ? "/usr/bin/xdg-open" : nil })
        XCTAssertEqual(command?.executable, "/usr/bin/xdg-open")
        XCTAssertEqual(command?.arguments, ["/home/k/Garmin/kmap/2026-08-27"])
    }

    func testLinuxWithNoOpenerAtAllOffersNothing() {
        // The footer leaves the key off rather than offering one that does nothing.
        XCTAssertNil(Platform.revealCommand(for: mapFile, on: .linux, which: { _ in nil }))
    }

    func testWslDrivesWindowsExplorerAndSelectsTheFile() {
        let onDrive = URL(fileURLWithPath: "/mnt/e/Garmin/region-a.img")
        let command = Platform.revealCommand(for: onDrive, on: .wsl,
                                             which: { $0 == "explorer.exe"
                                                 ? "/mnt/c/Windows/explorer.exe" : nil })
        XCTAssertEqual(command?.executable, "/mnt/c/Windows/explorer.exe")
        // One argument, with no space after the comma: given two, explorer.exe silently
        // opens Documents instead.
        XCTAssertEqual(command?.arguments, [#"/select,E:\Garmin\region-a.img"#])
    }

    func testWslFallsBackToTheLinuxOpenerForAFileWindowsCannotSee() {
        // Inside the distribution's own filesystem, with no wslpath to ask.
        let command = Platform.revealCommand(for: mapFile, on: .wsl, which: {
            switch $0 {
            case "explorer.exe": return "/mnt/c/Windows/explorer.exe"
            case "xdg-open": return "/usr/bin/xdg-open"
            default: return nil
            }
        })
        XCTAssertEqual(command?.executable, "/usr/bin/xdg-open")
    }

    func testWindowsAsksTheSameExplorerWithNothingToTranslateOnTheWay() {
        let onDrive = URL(fileURLWithPath: #"E:\Garmin\region-a.img"#)
        let command = Platform.revealCommand(for: onDrive, on: .windows,
                                             which: { $0 == "explorer.exe"
                                                 ? #"C:\Windows\explorer.exe"# : nil })
        XCTAssertEqual(command?.executable, #"C:\Windows\explorer.exe"#)
        // Explorer accepts only the `nativePath` spelling; on a POSIX host the drive
        // letter is a relative name, so only the tail can be compared.
        XCTAssertEqual(command?.arguments.first?.hasPrefix("/select,"), true)
        XCTAssertEqual(command?.arguments.count, 1)
        XCTAssertEqual(command?.arguments.first?.hasSuffix(onDrive.nativePath), true)
    }

    func testWindowsWithoutExplorerOffersNothingRatherThanAnEmptyCommand() {
        // With no shell installed the footer leaves the key off.
        XCTAssertNil(Platform.revealCommand(for: URL(fileURLWithPath: #"E:\x.img"#),
                                            on: .windows, which: { _ in nil }))
    }

    func testTheRevealKeyIsCalledWhatThatMachineCallsIt() {
        XCTAssertEqual(Platform.revealLabel(on: .macOS), t("reveal in Finder"))
        XCTAssertEqual(Platform.revealLabel(on: .wsl), t("show in Explorer"))
        XCTAssertEqual(Platform.revealLabel(on: .windows), t("show in Explorer"))
        XCTAssertEqual(Platform.revealLabel(on: .linux), t("open the folder"),
                       "xdg-open opens the folder, so the label may not promise more")
    }
}
