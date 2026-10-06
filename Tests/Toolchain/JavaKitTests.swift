import XCTest

@testable import kmap

#if !os(Windows)
/// Which JDK a Java's javac and jar come from.
final class JavaKitTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kmap-kit-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tools(_ names: [String], in folder: String) throws -> URL {
        let bin = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in names {
            let file = bin.appendingPathComponent(name)
            try FileTools.write("#!/bin/sh\n", to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return bin
    }

    /// Debian's alternatives: /usr/bin/java and /usr/bin/javac each lead to a JDK of their
    /// own choosing. The tools are those of the JDK java leads to.
    func testTheToolsComeFromTheJDKTheLinkLeadsTo() throws {
        let chosen = try tools(["java", "javac", "jar"], in: "jdk-17/bin")
        let other = try tools(["javac", "jar"], in: "jdk-21/bin")
        let links = root.appendingPathComponent("usr-bin")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("java"),
            withDestinationURL: chosen.appendingPathComponent("java")
        )
        for name in ["javac", "jar"] {
            try FileManager.default.createSymbolicLink(
                at: links.appendingPathComponent(name),
                withDestinationURL: other.appendingPathComponent(name)
            )
        }
        let java = links.appendingPathComponent("java").path
        XCTAssertEqual(
            JavaRuntime.kitTool("javac", beside: java),
            chosen.appendingPathComponent("javac").resolvingSymlinksInPath().path
        )
        XCTAssertTrue(JavaRuntime.isKit(at: java))
    }

    /// Gentoo's java is a link to a script that picks the JDK, with no tools beside it: the
    /// tools beside the link are taken.
    func testALinkToAChoosingScriptTakesTheToolsBesideTheLink() throws {
        let links = try tools(["javac", "jar"], in: "usr-bin")
        let chooser = try tools(["run-java-tool.bash"], in: "eselect")
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("java"),
            withDestinationURL: chooser.appendingPathComponent("run-java-tool.bash")
        )
        let java = links.appendingPathComponent("java").path
        XCTAssertEqual(JavaRuntime.kitTool("javac", beside: java), links.appendingPathComponent("javac").path)
        XCTAssertTrue(JavaRuntime.isKit(at: java))
    }

    /// A link to a runtime's own java takes nothing from beside the link: those tools are
    /// another JDK's, and would build for a Java this one cannot load.
    func testALinkToARuntimeIsNoKitWhateverStandsBesideTheLink() throws {
        let runtime = try tools(["java"], in: "jre-17/bin")
        let links = try tools(["javac", "jar"], in: "usr-bin")
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("java"),
            withDestinationURL: runtime.appendingPathComponent("java")
        )
        XCTAssertFalse(JavaRuntime.isKit(at: links.appendingPathComponent("java").path))
    }

    /// A folder carrying java and javac but no jar is not a JDK, so the search goes on.
    func testJavacWithoutJarIsNoKit() throws {
        let bin = try tools(["java", "javac"], in: "javapath")
        XCTAssertFalse(JavaRuntime.isKit(at: bin.appendingPathComponent("java").path))
    }
}
#endif
