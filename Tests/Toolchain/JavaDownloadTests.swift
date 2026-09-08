import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import kmap

/// The JDK kmap fetches for a machine whose package manager cannot provide one.
final class JavaDownloadTests: XCTestCase {

    // MARK: What is asked for

    func testEachPlatformAsksForItsOwnBuild() {
        XCTAssertEqual(JavaDownload.operatingSystem(.macOS), "mac")
        XCTAssertEqual(JavaDownload.operatingSystem(.linux), "linux")
        XCTAssertEqual(JavaDownload.operatingSystem(.windows), "windows")
        // WSL runs the jars inside the distribution, so it wants the Linux build.
        XCTAssertEqual(JavaDownload.operatingSystem(.wsl), "linux")
    }

    func testTheAddressNamesThePlatformTheProcessorAndTheImage() throws {
        let url = try XCTUnwrap(JavaDownload.assetsURL(on: .windows, architecture: "x64",
                                                       feature: 21))
        XCTAssertTrue(url.absoluteString.hasPrefix(
            "https://api.adoptium.net/v3/assets/latest/21/hotspot?"), url.absoluteString)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems)
        let asked = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(asked["os"], "windows")
        XCTAssertEqual(asked["architecture"], "x64")
        // A JDK and not a JRE: kmap compiles the mkgmap patch with javac.
        XCTAssertEqual(asked["image_type"], "jdk")
        XCTAssertEqual(asked["vendor"], "eclipse")
    }

    func testAProcessorWithNoPublishedBuildIsNotOfferedOne() {
        XCTAssertFalse(JavaDownload.isAvailable(on: .linux, architecture: "unknown"))
        XCTAssertTrue(JavaDownload.isAvailable(on: .linux, architecture: "x64"))
    }

    // MARK: Reading the answer

    private func asset(name: String, link: String, checksum: String?, size: Int = 100,
                       release: String = "jdk-21.0.1+12") -> [String: Any] {
        var package: [String: Any] = ["name": name, "link": link, "size": size]
        if let checksum { package["checksum"] = checksum }
        return ["release_name": release, "binary": ["package": package]]
    }

    private func data(_ objects: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: objects)
    }

    func testTheReleaseIsReadOutOfWhatTheApiAnswered() throws {
        let answer = try data([asset(
            name: "OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.1_12.tar.gz",
            link: "https://example.invalid/jdk.tar.gz",
            checksum: "ABCD1234", size: 200_073_404)])
        let release = try JavaDownload.release(fromAssets: answer)
        XCTAssertEqual(release.name, "jdk-21.0.1+12")
        XCTAssertEqual(release.fileName, "OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.1_12.tar.gz")
        XCTAssertEqual(release.link.absoluteString, "https://example.invalid/jdk.tar.gz")
        // Compared against a digest kmap computes in lower case.
        XCTAssertEqual(release.checksum, "abcd1234")
        XCTAssertEqual(release.bytes, 200_073_404)
    }

    func testABuildPublishedWithNoChecksumIsPassedOver() throws {
        // Nothing to check it against means nothing to check it with, so the next one is
        // taken instead.
        let answer = try data([
            asset(name: "unchecked.tar.gz", link: "https://example.invalid/a", checksum: nil),
            asset(name: "checked.tar.gz", link: "https://example.invalid/b", checksum: "ff"),
        ])
        XCTAssertEqual(try JavaDownload.release(fromAssets: answer).fileName, "checked.tar.gz")
    }

    func testAnEmptyListingIsAnError() throws {
        XCTAssertThrowsError(try JavaDownload.release(fromAssets: try data([]))) { error in
            XCTAssertEqual(error as? JavaDownload.Trouble, .noRelease)
        }
    }

    func testNonsenseFromTheApiIsAnErrorRatherThanACrash() {
        XCTAssertThrowsError(try JavaDownload.release(fromAssets: Data("not json".utf8)))
    }

    // MARK: Finding java in what was unpacked

    /// A directory listing and an executable test, standing in for a machine.
    private func tree(_ folders: [String], executable: Set<String>)
        -> (contents: (URL) -> [String], exists: (URL) -> Bool) {
        ({ url in url.path.hasSuffix("/jdk") ? folders : [] },
         { url in executable.contains(url.path) })
    }

    func testTheJdkUnpacksIntoAVersionNamedFolder() {
        let root = URL(fileURLWithPath: "/tools/jdk")
        let machine = tree(["jdk-21.0.1+12"], executable: ["/tools/jdk/jdk-21.0.1+12/bin/java"])
        XCTAssertEqual(
            JavaDownload.javaBinary(under: root, on: .linux,
                                    contents: machine.contents, exists: machine.exists)?.path,
            "/tools/jdk/jdk-21.0.1+12/bin/java")
    }

    func testOnAMacTheRuntimeSitsInsideTheBundle() {
        let root = URL(fileURLWithPath: "/tools/jdk")
        let machine = tree(["jdk-21.0.1+12"],
                           executable: ["/tools/jdk/jdk-21.0.1+12/Contents/Home/bin/java"])
        XCTAssertEqual(
            JavaDownload.javaBinary(under: root, on: .macOS,
                                    contents: machine.contents, exists: machine.exists)?.path,
            "/tools/jdk/jdk-21.0.1+12/Contents/Home/bin/java")
    }

    func testOnWindowsItIsJavaExe() {
        let root = URL(fileURLWithPath: "/tools/jdk")
        let machine = tree(["jdk-21.0.1+12"],
                           executable: ["/tools/jdk/jdk-21.0.1+12/bin/java.exe"])
        XCTAssertEqual(
            JavaDownload.javaBinary(under: root, on: .windows,
                                    contents: machine.contents, exists: machine.exists)?
                .lastPathComponent,
            "java.exe")
    }

    func testAnArchiveWithNoJavaInsideAnswersNothing() {
        let root = URL(fileURLWithPath: "/tools/jdk")
        let machine = tree(["docs"], executable: [])
        XCTAssertNil(JavaDownload.javaBinary(under: root, on: .linux,
                                             contents: machine.contents,
                                             exists: machine.exists))
    }
}

/// Where the probe looks for a JVM, and in what order.
final class JavaPreferenceTests: XCTestCase {

    private func candidates(own: String?, path: String?,
                            environment: [String: String] = [:]) -> [String] {
        ToolLocations.java(on: .linux, configured: "", environment: environment,
                           which: { name, _ in name == "java" ? path : nil },
                           contents: { _ in [] },
                           ownJava: { _ in own },
                           macJavaHome: { nil })
    }

    func testAJavaTheUserInstalledDeliberatelyWinsOverTheOneKmapFetched() {
        let found = candidates(own: "/home/u/.kmap/tools/jdk/jdk-21/bin/java",
                               path: "/usr/bin/java")
        let onPath = try? XCTUnwrap(found.firstIndex(of: "/usr/bin/java"))
        let own = try? XCTUnwrap(found.firstIndex(of: "/home/u/.kmap/tools/jdk/jdk-21/bin/java"))
        XCTAssertNotNil(onPath)
        XCTAssertNotNil(own)
        XCTAssertLessThan(onPath ?? 0, own ?? 0)
    }

    func testTheOneKmapFetchedBeatsTheWellKnownGuesses() {
        let found = candidates(own: "/home/u/.kmap/tools/jdk/jdk-21/bin/java", path: nil)
        let own = found.firstIndex(of: "/home/u/.kmap/tools/jdk/jdk-21/bin/java")
        let guess = found.firstIndex(of: "/usr/bin/java")
        XCTAssertNotNil(own)
        XCTAssertNotNil(guess)
        XCTAssertLessThan(own ?? 0, guess ?? 0)
    }

    func testWithNoJdkOfItsOwnTheListIsWhatItAlwaysWas() {
        XCTAssertFalse(candidates(own: nil, path: nil).contains { $0.contains(".kmap") })
    }
}

/// The mechanism, with a tarball made here standing in for the download: unpack, find the
/// java inside, and run it.
final class JavaUnpackTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-jdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// Builds `<folder>/bin/java` as a script that answers `-version` the way a JVM does,
    /// and packs it the way Adoptium does.
    private func makeTarball(layout: String) throws -> URL {
        #if os(Windows)
        throw XCTSkip("built with tar, which is spelled differently here")
        #else
        let tree = work.appendingPathComponent("tree", isDirectory: true)
        let bin = tree.appendingPathComponent(layout, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let java = bin.appendingPathComponent("java")
        try "#!/bin/sh\necho 'openjdk version \"21.0.1\" 2026-01-01' 1>&2\n"
            .write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: java.path)

        let tarball = work.appendingPathComponent("jdk.tar.gz")
        let tar = Process()
        tar.executableURL = try tarProgram()
        tar.arguments = ["-czf", tarball.path, "-C", tree.path, layout]
        try tar.run()
        tar.waitUntilExit()
        try XCTSkipUnless(tar.terminationStatus == 0, "tar could not pack the fixture")
        return tarball
        #endif
    }

    /// `tar`, wherever this machine keeps it. Windows has one and it is not in /usr/bin,
    /// which is where this used to look — the archive was never packed and the test failed
    /// with "The file doesn't exist" about a path nobody had mentioned.
    private func tarProgram() throws -> URL {
        let found = Platform.which("tar")
        return URL(fileURLWithPath: try XCTUnwrap(found, "no tar on this machine"))
    }

    private func unpack(_ tarball: URL) throws -> URL {
        let into = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let archive = try XCTUnwrap(Archive.found(.tarGzip), "this machine has no tar")
        let command = archive.unpack(tarball, into: into)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unpacking failed")
        return into
    }

    func testATarballUnpacksAndTheJavaInsideIsFoundAndRuns() throws {
        let root = try unpack(try makeTarball(layout: "jdk-21.0.1+12"))
        let java = try XCTUnwrap(JavaDownload.javaBinary(under: root, on: .linux))
        XCTAssertEqual(java.lastPathComponent, "java")
        // Found by the same test the toolchain probe makes: it has to actually run.
        let output = try XCTUnwrap(ProcessRunner.capture(java.path, ["-version"]))
        XCTAssertTrue(output.lowercased().contains("version"), output)
    }

    func testTheMacBundleLayoutIsFoundToo() throws {
        let root = try unpack(try makeTarball(layout: "jdk-21.0.1+12/Contents/Home"))
        XCTAssertNotNil(JavaDownload.javaBinary(under: root, on: .macOS))
    }

    func testAnArchiveOfSomethingElseIsRefusedRatherThanInstalled() throws {
        let tree = work.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        try "read me".write(to: tree.appendingPathComponent("docs/README"),
                            atomically: true, encoding: .utf8)
        let tarball = work.appendingPathComponent("other.tar.gz")
        let tar = Process()
        tar.executableURL = try tarProgram()
        tar.arguments = ["-czf", tarball.path, "-C", tree.path, "docs"]
        try tar.run()
        tar.waitUntilExit()
        let root = try unpack(tarball)
        XCTAssertNil(JavaDownload.javaBinary(under: root, on: .linux))
    }
}

/// The one thing that cannot be checked without the network: that Adoptium still answers
/// the way the parser expects. Skipped unless `KMAP_NET_TESTS` is set, so the suite stays
/// offline and quick.
final class JavaDownloadLiveTests: XCTestCase {

    func testTheApiStillAnswersInTheShapeTheParserReads() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KMAP_NET_TESTS"] != nil,
                          "set KMAP_NET_TESTS to ask Adoptium")
        for platform: Platform in [.macOS, .linux, .windows] {
            for architecture in ["x64", "aarch64"] {
                let url = try XCTUnwrap(JavaDownload.assetsURL(on: platform,
                                                               architecture: architecture))
                var request = URLRequest(url: url)
                request.setValue("kmap/\(Version.number)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                               "\(platform) \(architecture)")
                let release = try JavaDownload.release(fromAssets: data)
                XCTAssertEqual(release.checksum.count, 64, "a SHA-256 in hex")
                XCTAssertGreaterThan(release.bytes, 50_000_000, "a JDK is not small")
                XCTAssertTrue(release.link.absoluteString.hasPrefix("https://"),
                              release.link.absoluteString)
                // Windows is published as a zip and the rest as a gzip tarball; the
                // installer picks its unpacker from this.
                XCTAssertEqual(release.fileName.hasSuffix(".zip"),
                               platform == .windows, release.fileName)
            }
        }
    }
}
