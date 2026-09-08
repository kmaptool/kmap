import XCTest
@testable import kmap

/// The system's file dialog, asked for a path.
///
/// Which helper is picked on which platform, what it is asked, and what is made of what
/// comes back. The platform is passed in rather than detected, so every case runs
/// anywhere.
final class FilePickerTests: XCTestCase {

    private let everything: (String) -> Bool = { _ in true }
    private let nothing: (String) -> Bool = { _ in false }

    // MARK: Which helper

    func testAMacAlwaysHasOsascript() {
        let found = FilePicker.helper(platform: .macOS, environment: [:], exists: everything)
        XCTAssertEqual(found?.kind, .osascript)
        XCTAssertEqual(found?.path, "/usr/bin/osascript")
        XCTAssertNil(FilePicker.helper(platform: .macOS, environment: [:], exists: nothing))
    }

    func testLinuxNeedsADisplayBeforeItLooksForOne() {
        // Without a display a dialog has nothing to appear on and would hang, then fail.
        XCTAssertNil(FilePicker.helper(platform: .linux, environment: ["PATH": "/usr/bin"],
                                       exists: everything))
    }

    func testTheFirstOfTheThreeInstalledWins() {
        let environment = ["DISPLAY": ":0", "PATH": "/opt/bin:/usr/bin"]
        let onlyKdialog = FilePicker.helper(platform: .linux, environment: environment,
                                            exists: { $0.hasSuffix("kdialog") })
        XCTAssertEqual(onlyKdialog?.kind, .kdialog)
        XCTAssertEqual(onlyKdialog?.path, "/opt/bin/kdialog")
        XCTAssertNil(FilePicker.helper(platform: .linux, environment: environment,
                                       exists: nothing))
    }

    func testWaylandCountsAsADisplay() {
        let found = FilePicker.helper(platform: .linux,
                                      environment: ["WAYLAND_DISPLAY": "wayland-0",
                                                    "PATH": "/usr/bin"],
                                      exists: { $0.hasSuffix("zenity") })
        XCTAssertEqual(found?.kind, .zenity)
    }

    // MARK: WSL

    func testWslReachesForWindowsOwnDialogAndNeedsNoDisplayToDoIt() {
        // The desktop is Windows'; powershell.exe is present whenever interop is on.
        let found = FilePicker.helper(platform: .wsl,
                                      environment: ["PATH": "/usr/bin:/mnt/c/Windows/System32"],
                                      exists: { $0 == "/mnt/c/Windows/System32/powershell.exe" })
        XCTAssertEqual(found?.kind, .powershell)
        XCTAssertEqual(found?.path, "/mnt/c/Windows/System32/powershell.exe",
                       "found where PATH says it is, rather than at a name guessed here")
    }

    func testWslFallsBackToALinuxDialogWhenInteropIsOff() {
        // Interop can be switched off in wsl.conf, and WSLg may still be giving a desktop.
        let found = FilePicker.helper(platform: .wsl,
                                      environment: ["DISPLAY": ":0", "PATH": "/usr/bin"],
                                      exists: { $0.hasSuffix("zenity") })
        XCTAssertEqual(found?.kind, .zenity)
    }

    func testWslWithNeitherOffersNothingRatherThanSomethingThatHangs() {
        // No helper means the footer drops the key rather than offering a dead one.
        XCTAssertNil(FilePicker.helper(platform: .wsl, environment: ["PATH": "/usr/bin"],
                                       exists: nothing))
    }

    // MARK: Windows, with no Linux underneath

    func testWindowsAsksPowershellDirectlyAndHasNothingToTranslate() {
        let found = FilePicker.helper(platform: .windows,
                                      environment: ["PATH": #"C:\Windows\System32"#],
                                      exists: { $0 == #"C:\Windows\System32\powershell.exe"# })
        XCTAssertEqual(found?.kind, .powershell)
        XCTAssertEqual(found?.path, #"C:\Windows\System32\powershell.exe"#)
        // Unlike WSL, the answer is already a name this process can open.
        XCTAssertEqual(found?.answersInForeignPaths, false)
    }

    func testWslAndWindowsRunTheSameDialogAndDifferOnlyInWhatComesBack() {
        let wsl = FilePicker.helper(platform: .wsl,
                                    environment: ["PATH": "/mnt/c/Windows/System32"],
                                    exists: { $0.hasSuffix("powershell.exe") })
        let windows = FilePicker.helper(platform: .windows,
                                        environment: ["PATH": #"C:\Windows\System32"#],
                                        exists: { $0.hasSuffix("powershell.exe") })
        XCTAssertEqual(wsl?.kind, windows?.kind)
        XCTAssertEqual(wsl?.answersInForeignPaths, true)
        XCTAssertEqual(windows?.answersInForeignPaths, false)
    }

    func testWindowsWithNoPowershellAtAllOffersNothing() {
        XCTAssertNil(FilePicker.helper(platform: .windows,
                                       environment: ["PATH": #"C:\Windows\System32"#],
                                       exists: nothing))
    }

    func testAWindowsAnswerIsOpenedAsWrittenWhenThereIsNoBoundaryToCross() {
        let chosen = FilePicker.path(from: #"E:\Garmin\style.typ"# + "\r\n",
                                     kind: .powershell, translating: false,
                                     toLinux: { _ in
                                         XCTFail("nothing to translate on Windows")
                                         return nil
                                     })
        // On a POSIX host `E:\…` is a relative name, so only the tail is compared.
        XCTAssertEqual(chosen?.nativePath.hasSuffix(#"E:\Garmin\style.typ"#), true)
    }

    // MARK: What it is asked

    func testTheMacIsAskedForAFileOfTheTypesWanted() {
        let arguments = FilePicker.arguments(for: .osascript,
                                             wanted: .file(extensions: ["typ", "img"]),
                                             startingAt: URL(fileURLWithPath: "/Volumes/Disk"),
                                             prompt: "import a TYP")
        XCTAssertEqual(arguments.first, "-e")
        let script = arguments.last ?? ""
        XCTAssertTrue(script.contains("choose file"))
        XCTAssertTrue(script.contains("of type {\"typ\", \"img\"}"))
        XCTAssertTrue(script.contains("default location POSIX file \"/Volumes/Disk\""))
        XCTAssertTrue(script.hasPrefix("POSIX path of"), "the path is what is wanted back")
    }

    func testAFolderIsADifferentQuestionEverywhere() {
        XCTAssertTrue(FilePicker.arguments(for: .osascript, wanted: .directory,
                                           startingAt: nil, prompt: "Output folder")
                        .last?.contains("choose folder") == true)
        XCTAssertTrue(FilePicker.arguments(for: .zenity, wanted: .directory,
                                           startingAt: nil, prompt: "Output folder")
                        .contains("--directory"))
        XCTAssertTrue(FilePicker.arguments(for: .kdialog, wanted: .directory,
                                           startingAt: nil, prompt: "Output folder")
                        .contains("--getexistingdirectory"))
    }

    func testZenityIsGivenTheExtensionsAsPatterns() {
        let arguments = FilePicker.arguments(for: .zenity,
                                             wanted: .file(extensions: ["png", "svg"]),
                                             startingAt: nil, prompt: "an icon")
        XCTAssertTrue(arguments.contains("--file-filter=*.png *.svg"))
    }

    func testAPromptCannotBreakOutOfTheScriptItIsPutIn() {
        // The prompt sits inside quotes in the AppleScript, where a quote of its own
        // would end the string early.
        let arguments = FilePicker.arguments(for: .osascript, wanted: .directory,
                                             startingAt: nil,
                                             prompt: "say \"hi\"\nand more")
        let script = arguments.last ?? ""
        XCTAssertFalse(script.contains("\n"))
        XCTAssertEqual(script.filter { $0 == "\"" }.count, 2,
                       "one pair of quotes, around the prompt: \(script)")
    }

    // MARK: The Windows dialog

    /// The script as PowerShell will see it, decoded back out of the base64.
    private func windowsScript(_ wanted: FilePicker.Wanted, prompt: String,
                               startingAt start: URL? = nil,
                               windowsPath: @escaping (URL) -> String? = { _ in nil })
        throws -> String {
        let arguments = FilePicker.arguments(for: .powershell, wanted: wanted,
                                             startingAt: start, prompt: prompt,
                                             windowsPath: windowsPath)
        XCTAssertEqual(arguments.first, "-NoProfile")
        XCTAssertTrue(arguments.contains("-Sta"), "WinForms needs a single-threaded apartment")
        let index = try XCTUnwrap(arguments.firstIndex(of: "-EncodedCommand"))
        XCTAssertLessThan(index + 1, arguments.count)
        let data = try XCTUnwrap(Data(base64Encoded: arguments[index + 1]))
        // Back out of the little-endian UTF-16 that `-EncodedCommand` is defined in.
        XCTAssertEqual(data.count % 2, 0)
        let units = stride(from: 0, to: data.count, by: 2).map {
            UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
        }
        return String(decoding: units, as: UTF16.self)
    }

    func testWindowsIsAskedForAFileOfTheTypesWanted() throws {
        let script = try windowsScript(.file(extensions: ["typ", "img"]), prompt: "import a TYP")
        XCTAssertTrue(script.contains("OpenFileDialog"), script)
        XCTAssertTrue(script.contains("$d.Filter = 'Supported|*.typ;*.img|All files|*.*'"), script)
        XCTAssertTrue(script.contains("$d.Title = 'import a TYP'"), script)
        XCTAssertTrue(script.contains("$d.FileName"), script)
    }

    func testWindowsIsAskedForAFolderWithTheOtherDialogEntirely() throws {
        let script = try windowsScript(.directory, prompt: "Output folder")
        XCTAssertTrue(script.contains("FolderBrowserDialog"), script)
        XCTAssertTrue(script.contains("$d.Description = 'Output folder'"), script)
        XCTAssertTrue(script.contains("$d.SelectedPath"), script)
    }

    func testProgressReportingIsSilencedBecauseItArrivesAsXmlGluedToTheAnswer() throws {
        // `Add-Type` reports progress, and PowerShell serialises that as CLIXML onto the
        // same line as the answer whenever its output is a pipe.
        let script = try windowsScript(.directory, prompt: "pick")
        XCTAssertTrue(script.hasPrefix("$ProgressPreference = 'SilentlyContinue'"), script)
    }

    func testTheAnswerSurvivesEvenIfSomethingElseSerialisesItselfOntoTheEnd() {
        // Anything else on PowerShell's error stream arrives in the same shape.
        let noisy = "#< CLIXML\n" + #"E:\Garmin\style.typ"#
            + #"<Objs Version="1.1.0.1" xmlns="http://x"><Obj S="progress" /></Objs>"#
        XCTAssertEqual(FilePicker.path(from: noisy, kind: .powershell, translating: true)?.path,
                       "/mnt/e/Garmin/style.typ")
    }

    func testStrippingTheXmlLeavesAnOrdinaryAnswerAlone() {
        XCTAssertEqual(FilePicker.withoutSerialisedObjects(#"E:\Garmin\x.typ"#),
                       #"E:\Garmin\x.typ"#)
        XCTAssertEqual(FilePicker.withoutSerialisedObjects(""), "")
    }

    func testTheAnswerComesBackAsUtf8SoACyrillicFolderSurvivesThePipe() throws {
        let script = try windowsScript(.directory, prompt: "pick")
        XCTAssertTrue(script.contains("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"),
                      script)
    }

    func testTheStartingFolderIsHandedOverAsAWindowsPath() throws {
        let script = try windowsScript(.file(extensions: []), prompt: "pick",
                                       startingAt: URL(fileURLWithPath: "/mnt/e/Garmin"),
                                       windowsPath: { _ in #"E:\Garmin"# })
        XCTAssertTrue(script.contains(#"$d.InitialDirectory = 'E:\Garmin'"#), script)
    }

    func testAFolderInsideLinuxIsSimplyNotOfferedAsAStartingPoint() throws {
        // A path with no drive letter cannot be resolved by the dialog, so none is given
        // and it opens wherever Windows would.
        let script = try windowsScript(.directory, prompt: "pick",
                                       startingAt: URL(fileURLWithPath: "/home/k/.kmap"))
        XCTAssertFalse(script.contains("SelectedPath = "), script)
    }

    func testAQuoteInAPromptCannotEndTheStringItSitsIn() throws {
        // PowerShell escapes a quote inside a literal string by doubling it.
        let script = try windowsScript(.directory, prompt: "it's a 'folder'")
        XCTAssertTrue(script.contains("$d.Description = 'it''s a ''folder'''"), script)
    }

    func testTheScriptIsHandedOverEncodedRatherThanQuoted() {
        // The arguments are reassembled into one command line on the way across, and
        // base64 leaves nothing for that to act on.
        let arguments = FilePicker.arguments(for: .powershell, wanted: .directory,
                                             startingAt: nil,
                                             prompt: #"a " quote \ and a slash"#)
        let encoded = arguments.last ?? ""
        XCTAssertNotNil(Data(base64Encoded: encoded))
        XCTAssertFalse(encoded.contains("\""), "nothing left to re-parse: \(encoded)")
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertFalse(encoded.contains("\\"))
    }

    func testEncodingIsUtf16LittleEndianAsPowershellExpects() {
        XCTAssertEqual(FilePicker.encoded("Hi"),
                       Data([0x48, 0x00, 0x69, 0x00]).base64EncodedString())
        XCTAssertEqual(FilePicker.encoded("я"), Data([0x4F, 0x04]).base64EncodedString())
    }

    // MARK: What comes back

    func testAPathComesBackAndAnythingElseDoesNot() {
        XCTAssertEqual(FilePicker.path(from: "/Volumes/Disk/style.typ\n")?.path,
                       "/Volumes/Disk/style.typ")
        // Cancelling reads differently in every dialect and is not an error.
        XCTAssertNil(FilePicker.path(from: ""))
        XCTAssertNil(FilePicker.path(from: "execution error: User canceled. (-128)\n"))
        XCTAssertNil(FilePicker.path(from: "kdialog: command not found\n"))
        XCTAssertNil(FilePicker.path(from: "   \n\n"))
    }

    func testAFolderComesBackWithoutItsTrailingSlash() {
        // osascript ends a folder with one; the rest of kmap keeps paths without.
        XCTAssertEqual(FilePicker.path(from: "/Users/someone/Maps/")?.path,
                       "/Users/someone/Maps")
        XCTAssertEqual(FilePicker.path(from: "/")?.path, "/")
    }

    func testAPathWithSpacesSurvivesWhole() {
        let path = "/Volumes/Disk/Garmin/Third Party/1540-Topo-10m/style.typ"
        XCTAssertEqual(FilePicker.path(from: path + "\n")?.path, path)
    }

    func testAWindowsPathIsConvertedToOneThisProcessCanOpen() {
        // Windows prints CRLF, and the drive letter has to become a mount point.
        let url = FilePicker.path(from: #"E:\Garmin\style.typ"# + "\r\n", kind: .powershell,
                                  translating: true)
        XCTAssertEqual(url?.path, "/mnt/e/Garmin/style.typ")
    }

    func testAWindowsPathWithSpacesAndCyrillicSurvives() {
        let url = FilePicker.path(from: #"E:\Garmin\Карты Региона\style.typ"#,
                                  kind: .powershell, translating: true)
        XCTAssertEqual(url?.path, "/mnt/e/Garmin/Карты Региона/style.typ")
    }

    func testACancelledWindowsDialogPrintsNothingAndMeansNothing() {
        XCTAssertNil(FilePicker.path(from: "", kind: .powershell, translating: true))
        XCTAssertNil(FilePicker.path(from: "\r\n", kind: .powershell, translating: true))
    }

    func testSomewhereWindowsCanReachAndLinuxCannotIsRefusedRatherThanGuessed() {
        // A network share has no path under /mnt, so nothing comes back.
        XCTAssertNil(FilePicker.path(from: #"\\server\share\map.typ"#, kind: .powershell,
                                     translating: true))
        XCTAssertNil(FilePicker.path(from: "Documents", kind: .powershell, translating: true))
    }

    func testTheOtherDialectsAreStillReadAsPosixPaths() {
        XCTAssertNil(FilePicker.path(from: #"E:\Garmin\x.typ"#, kind: .zenity),
                     "a Windows path from zenity would be nonsense")
        XCTAssertEqual(FilePicker.path(from: "/home/k/x.typ", kind: .zenity)?.path,
                       "/home/k/x.typ")
    }

    // MARK: Not from here

    func testATestRunKnowsItIsOne() {
        XCTAssertTrue(FilePicker.underTest,
                      "if this is false the dialog will open on somebody's screen")
    }

    func testTheDialogNeverOpensFromATest() {
        // The dialog blocks until it is closed, so a test run must never open one.
        XCTAssertNil(FilePicker.choose(.directory, prompt: "this must not appear"))
        XCTAssertNil(FilePicker.choose(.file(extensions: ["typ"]), prompt: "nor this"))
    }
}
