import Foundation

/// A Java runtime kmap fetches itself, for a machine with no package manager to ask.
///
/// mkgmap is a Java program, so without a JVM kmap cannot build a map at all. A Mac without Homebrew and a Windows without winget are both ordinary machines,
/// and neither has one. So kmap downloads a JDK the way it already downloads mkgmap: into
/// its own directory, touching nothing else on the machine, needing no password.
///
/// The build comes from Adoptium (Eclipse Temurin), whose API states the archive's SHA-256
/// alongside its address; the download is checked against it before anything is unpacked.
///
/// Everything here but `install` is pure, so the address built for any platform can be
/// tested from any other.
enum JavaDownload {

    /// Which Java to ask for. A long-term release rather than the newest: mkgmap is old
    /// code, and this is the version it is tested against.
    static let feature = 21

    // MARK: What to ask for

    /// Adoptium's name for the operating system, or nil where it publishes no build.
    static func operatingSystem(_ platform: Platform) -> String? {
        switch platform {
        case .macOS: return "mac"
        // WSL runs a Linux JVM: the jars are run inside the distribution, not on Windows.
        case .linux, .wsl: return "linux"
        case .windows: return "windows"
        }
    }

    /// Adoptium's name for the processor, from the one this build was compiled for.
    ///
    /// A build running under Rosetta reports x64 and gets an x64 JDK, which is right: it
    /// is the architecture the process can actually execute.
    static var architecture: String {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x64"
        #elseif arch(arm)
        return "arm"
        #else
        return "unknown"
        #endif
    }

    /// Whether a JDK can be fetched for this machine at all.
    static func isAvailable(on platform: Platform = Platform.current,
                            architecture: String = JavaDownload.architecture) -> Bool {
        operatingSystem(platform) != nil && architecture != "unknown"
    }

    /// The API call that names the current release for this machine.
    static func assetsURL(on platform: Platform = Platform.current,
                          architecture: String = JavaDownload.architecture,
                          feature: Int = JavaDownload.feature) -> URL? {
        guard let os = operatingSystem(platform) else { return nil }
        var components = URLComponents(
            string: "https://api.adoptium.net/v3/assets/latest/\(feature)/hotspot")
        components?.queryItems = [
            URLQueryItem(name: "architecture", value: architecture),
            URLQueryItem(name: "image_type", value: "jdk"),
            URLQueryItem(name: "os", value: os),
            URLQueryItem(name: "vendor", value: "eclipse"),
        ]
        return components?.url
    }

    /// One published build: where it is, what it weighs, and what it must hash to.
    struct Release: Equatable {
        let name: String
        let fileName: String
        let link: URL
        let checksum: String
        let bytes: Int
    }

    enum Trouble: Error, Equatable, CustomStringConvertible {
        case unsupportedMachine
        case noRelease
        case badChecksum(expected: String, got: String)
        case noJavaInside

        var description: String {
            switch self {
            case .unsupportedMachine:
                return t("no Java build is published for this kind of machine")
            case .noRelease:
                return t("Adoptium listed no Java %d build for this machine",
                         JavaDownload.feature)
            case .badChecksum(let expected, let got):
                return t("the download does not match its published checksum"
                         + " (expected %1$@, got %2$@)", expected, got)
            case .noJavaInside:
                return t("the downloaded archive holds no java")
            }
        }
    }

    /// Reads the release out of what the API answered.
    ///
    /// The API returns a list, newest first, and kmap takes the first entry that carries a
    /// package with a checksum: a build published without one cannot be checked, so it is
    /// not used.
    static func release(fromAssets data: Data) throws -> Release {
        let listed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        for entry in listed ?? [] {
            guard let binary = entry["binary"] as? [String: Any],
                  let package = binary["package"] as? [String: Any],
                  let name = package["name"] as? String,
                  let address = package["link"] as? String,
                  let link = URL(string: address),
                  let checksum = package["checksum"] as? String, !checksum.isEmpty
            else { continue }
            let release = entry["release_name"] as? String ?? name
            let bytes = package["size"] as? Int ?? 0
            return Release(name: release, fileName: name, link: link,
                           checksum: checksum.lowercased(), bytes: bytes)
        }
        throw Trouble.noRelease
    }

    // MARK: Where it lands

    /// The directory kmap's own JDK is unpacked into. One JDK at a time: a second would
    /// only raise the question of which is used.
    static var home: URL { Paths.tools.appendingPathComponent("jdk", isDirectory: true) }

    /// The `java` inside an unpacked JDK, or nil where the archive held none.
    ///
    /// Temurin unpacks to a single version-named folder. On macOS a JDK is a bundle, so
    /// the runtime sits under `Contents/Home`; elsewhere it is directly inside.
    static func javaBinary(under root: URL, on platform: Platform = Platform.current,
                           contents: (URL) -> [String] = Self.namesInDirectory,
                           exists: (URL) -> Bool = { FileTools.isExecutable($0.path) })
        -> URL? {
        let leaf = platform.usesWindowsPaths ? "java.exe" : "java"
        var roots = [root]
        roots += contents(root).sorted().map { root.appendingPathComponent($0,
                                                                          isDirectory: true) }
        for base in roots {
            for inner in [base, base.appendingPathComponent("Contents/Home",
                                                            isDirectory: true)] {
                let candidate = inner.appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(leaf)
                if exists(candidate) { return candidate }
            }
        }
        return nil
    }

    /// kmap's own `java`, or nil where none has been installed.
    static func installed(on platform: Platform = Platform.current) -> URL? {
        javaBinary(under: home, on: platform)
    }

    private static func namesInDirectory(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }
}
