import XCTest
@testable import kmap

/// How this machine installs system software, and whether kmap may do it.
///
/// A package name has to be right for each distribution, and no install may stop for a
/// password: a prompt behind a full-screen interface never appears.
final class PackageManagerTests: XCTestCase {

    // MARK: Finding it

    func testTheDistributionsOwnManagerIsPreferredOverAnythingElseInstalled() {
        // Homebrew may be present on Linux; the distribution's own manager still wins.
        let found = PackageManager.detect(on: .linux, which: {
            ["apt-get", "brew"].contains($0) ? "/usr/bin/" + $0 : nil
        })
        XCTAssertEqual(found, .apt)
    }

    func testAMacPrefersHomebrewBecauseItIsTheOneThatDoesNotNeedRoot() {
        let found = PackageManager.detect(on: .macOS, which: { "/opt/homebrew/bin/" + $0 })
        XCTAssertEqual(found, .homebrew)
    }

    func testEachDistributionFindsItsOwn() {
        // winget is excluded: it installs Windows software, reachable from Linux only
        // through a WSL interop path.
        for manager in PackageManager.allCases where manager != .winget {
            let found = PackageManager.detect(on: .linux,
                                              which: { $0 == manager.binary ? "/usr/bin/" + $0 : nil })
            XCTAssertEqual(found, manager, "looking for \(manager.binary)")
        }
        XCTAssertNil(PackageManager.detect(on: .linux,
                                           which: { $0 == "winget" ? "/mnt/c/winget.exe" : nil }))
    }

    func testWslIsJustLinuxHere() {
        // A WSL install carries an ordinary distribution package manager.
        let found = PackageManager.detect(on: .wsl,
                                          which: { $0 == "pacman" ? "/usr/bin/pacman" : nil })
        XCTAssertEqual(found, .pacman)
    }

    func testAMachineWithNoneOfThemIsNoneOfThem() {
        XCTAssertNil(PackageManager.detect(on: .linux, which: { _ in nil }))
    }

    // MARK: The names each one uses

    func testTheJavaPackageIsNamedTheWayEachDistributionNamesIt() {
        XCTAssertEqual(PackageManager.homebrew.packages(for: .java), ["openjdk"])
        XCTAssertEqual(PackageManager.apt.packages(for: .java), ["default-jdk"])
        XCTAssertEqual(PackageManager.pacman.packages(for: .java), ["jdk-openjdk"])
        XCTAssertEqual(PackageManager.zypper.packages(for: .java), ["java-openjdk-devel"])
    }

    func testDebianIsAskedForTheVenvPackageAsWell() {
        // The virtualenv for pyhgtmap needs a separate package on Debian; python3 alone
        // fails at the first `-m venv`.
        XCTAssertEqual(PackageManager.apt.packages(for: .python), ["python3", "python3-venv"])
        XCTAssertEqual(PackageManager.pacman.packages(for: .python), ["python"],
                       "and Arch ships venv inside python itself")
    }

    func testEveryManagerHasANameForEveryThingKmapNeeds() {
        for manager in PackageManager.allCases {
            for need in [PackageManager.Need.java, .python, .unzip] {
                // Windows unpacks a zip itself, so there is nothing to name; elsewhere
                // a nil names a package that does not exist.
                if manager == .winget, need == .unzip {
                    XCTAssertNil(manager.packages(for: need))
                    continue
                }
                XCTAssertNotNil(manager.packages(for: need),
                                "\(manager.binary) has no name for \(need)")
            }
        }
    }

    // MARK: Windows

    func testWindowsHasTheOneManagerAndDoesNotGoLookingForApt() {
        XCTAssertEqual(PackageManager.detect(on: .windows, which: { _ in "found" }), .winget)
        // Other managers on PATH do not change the answer on Windows.
        XCTAssertEqual(PackageManager.detect(on: .windows,
                                             which: { $0 == "winget" ? #"C:\w\winget.exe"# : "x" }),
                       .winget)
    }

    func testAWindowsWithoutWingetSaysSoRatherThanNamingSomethingElse() {
        // Without App Installer there is no manager to name, and the command is printed
        // to paste instead.
        XCTAssertNil(PackageManager.detect(on: .windows, which: { _ in nil }))
    }

    func testWingetInstallsWithoutRootBecauseThereIsNoSuchThingOnWindows() {
        let privilege = Privilege.forInstalling(with: .winget, isRoot: false,
                                                hasSudo: false, sudoIsPasswordless: false)
        XCTAssertEqual(privilege, .direct)
        let command = PackageManager.winget.command(for: .java, privilege: privilege)
        XCTAssertEqual(command?.executable, "winget")
        XCTAssertEqual(command?.runnable, true)
        XCTAssertFalse(command?.arguments.contains("sudo") ?? true)
    }

    func testWingetIsAskedByPublisherAndProductRatherThanByFilename() {
        // winget identifies a package by publisher and product, not by a distribution's
        // name for it.
        XCTAssertEqual(PackageManager.winget.packages(for: .java), ["Microsoft.OpenJDK.21"])
        XCTAssertEqual(PackageManager.winget.packages(for: .python), ["Python.Python.3.12"])
        // Windows opens a zip with its own tar, so nothing is named for it.
        XCTAssertNil(PackageManager.winget.packages(for: .unzip))
        for need in [PackageManager.Need.java, .python] {
            let arguments = PackageManager.winget.installArguments(
                PackageManager.winget.packages(for: need) ?? [])
            XCTAssertEqual(arguments.last, PackageManager.winget.packages(for: need)?.first)
            XCTAssertEqual(arguments[arguments.count - 2], "--id",
                           "the id has to be introduced as one, or winget searches names")
        }
    }

    func testWingetIsToldNotToStopAndAskAnything() {
        // Children run with stdin on /dev/null, so the installer's own prompt and the
        // source agreement would each hang.
        let arguments = PackageManager.winget.installArguments(["Microsoft.OpenJDK.21"])
        for flag in ["--silent", "--disable-interactivity",
                     "--accept-package-agreements", "--accept-source-agreements"] {
            XCTAssertTrue(arguments.contains(flag), "winget is missing \(flag)")
        }
    }

    // MARK: Never asking a question

    func testEveryManagerIsInvokedInAWayThatCannotStopAndAsk() {
        // Every child runs with stdin on /dev/null, so a manager that paused to confirm
        // would hang.
        let confirmations: [PackageManager: String] = [
            .apt: "-y", .dnf: "-y", .yum: "-y",
            .pacman: "--noconfirm", .zypper: "--non-interactive",
            .apk: "--no-cache", .xbps: "-Sy"
        ]
        for (manager, flag) in confirmations {
            XCTAssertTrue(manager.installArguments(["x"]).contains(flag),
                          "\(manager.binary) is missing \(flag)")
        }
    }

    // MARK: Whether kmap may run it

    func testHomebrewNeedsNothingSpecialBecauseItRefusesToBeRoot() {
        let privilege = Privilege.forInstalling(with: .homebrew, isRoot: false,
                                                hasSudo: false, sudoIsPasswordless: false)
        XCTAssertEqual(privilege, .direct)
        let command = PackageManager.homebrew.command(for: .java, privilege: privilege)
        XCTAssertEqual(command?.executable, "brew")
        XCTAssertTrue(command?.runnable == true)
    }

    func testAlreadyBeingRootIsEnough() {
        // The case inside a container.
        XCTAssertEqual(Privilege.forInstalling(with: .apt, isRoot: true, hasSudo: false,
                                               sudoIsPasswordless: false), .direct)
    }

    func testPasswordlessSudoIsUsedAndSaysSoInTheCommand() {
        let privilege = Privilege.forInstalling(with: .apt, isRoot: false, hasSudo: true,
                                                sudoIsPasswordless: true)
        XCTAssertEqual(privilege, .passwordlessSudo)
        let command = PackageManager.apt.command(for: .java, privilege: privilege)
        XCTAssertEqual(command?.executable, "sudo")
        XCTAssertEqual(command?.arguments.first, "apt-get")
        XCTAssertTrue(command?.runnable == true)
    }

    func testSudoThatWouldAskIsNotRunAtAll() {
        // The prompt would be invisible behind the interface, so it is ruled out before
        // anything starts.
        let privilege = Privilege.forInstalling(with: .apt, isRoot: false, hasSudo: true,
                                                sudoIsPasswordless: false)
        XCTAssertEqual(privilege, .wouldAsk)
        XCTAssertFalse(privilege.canRunUnattended)
        XCTAssertFalse(PackageManager.apt.command(for: .java, privilege: privilege)?.runnable
                       ?? true)
    }

    func testNoSudoAtAllIsTheSameAsSudoThatWouldAsk() {
        XCTAssertEqual(Privilege.forInstalling(with: .dnf, isRoot: false, hasSudo: false,
                                               sudoIsPasswordless: true), .wouldAsk)
    }

    func testTheSudoProbeItselfCannotBecomeThePromptItIsCheckingFor() {
        // `-n` tells sudo to fail rather than read from a terminal.
        var asked: [String] = []
        _ = Privilege.sudoIsPasswordless(runner: { _, arguments in
            asked = arguments
            return 1
        })
        if !asked.isEmpty { XCTAssertEqual(asked.first, "-n") }
    }

    // MARK: The line a person is shown when kmap cannot do it

    func testTheSpokenCommandIsWhatSomebodyWouldActuallyType() {
        XCTAssertEqual(PackageManager.apt.spokenCommand(for: .java, privilege: .wouldAsk),
                       "sudo apt install -y --no-install-recommends default-jdk")
        XCTAssertEqual(PackageManager.homebrew.spokenCommand(for: .python, privilege: .direct),
                       "brew install python")
        XCTAssertEqual(PackageManager.apk.spokenCommand(for: .unzip, privilege: .direct),
                       "apk add --no-cache unzip")
    }

    func testItSaysAptRatherThanAptGetBecauseThatIsWhatPeopleType() {
        // apt-get is run for its stable interface; apt is the name shown.
        XCTAssertEqual(PackageManager.apt.binary, "apt-get")
        XCTAssertEqual(PackageManager.apt.spokenName, "apt")
        XCTAssertTrue(PackageManager.apt.spokenCommand(for: .unzip, privilege: .direct)?
                        .hasPrefix("apt install") == true)
    }

    func testRootIsNotSuggestedWhereItIsNotNeeded() {
        XCTAssertFalse(PackageManager.homebrew.spokenCommand(for: .java, privilege: .direct)?
                        .contains("sudo") ?? true)
        XCTAssertFalse(PackageManager.apt.spokenCommand(for: .java, privilege: .direct)?
                        .contains("sudo") ?? true,
                       "already root, so nothing to elevate")
    }
}
