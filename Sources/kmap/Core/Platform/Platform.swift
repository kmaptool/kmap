import Foundation

/// The host platform, and the behaviour that differs by it.
///
/// WSL is separate from plain Linux because its file dialog, file manager and removable
/// media are the Windows ones, reached through translated paths.
enum Platform: Equatable {
    case macOS
    case linux
    /// Linux running inside Windows Subsystem for Linux.
    case wsl
    /// Windows, with no Linux under it.
    case windows

    static let current: Platform = detect()

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osRelease: @autoclosure () -> String? = readOSRelease()
    ) -> Platform {
        #if canImport(Darwin)
        return .macOS
        #elseif os(Windows)
        return .windows
        #else
        // Set by WSL for every shell it starts.
        if environment["WSL_DISTRO_NAME"] != nil || environment["WSL_INTEROP"] != nil {
            return .wsl
        }
        // A kernel built by Microsoft names itself in its release string; catches a
        // process started outside a login shell, where the variables are absent.
        if let release = osRelease()?.lowercased(),
           release.contains("microsoft") || release.contains("wsl") {
            return .wsl
        }
        return .linux
        #endif
    }

    var isWSL: Bool { self == .wsl }

    /// WSL 1 translates Linux calls rather than running a kernel, and some come back
    /// wrong. The release string tells: `-Microsoft` for WSL 1, `microsoft-standard-WSL2` for 2.
    static let isWSL1: Bool = current == .wsl && isFirstWSL(release: readOSRelease())

    static func isFirstWSL(release: String?) -> Bool {
        guard let release else { return false }
        return release.contains("-Microsoft") && !release.lowercased().contains("wsl2")
    }

    static func readOSRelease() -> String? {
        try? String(contentsOf: URL(fileURLWithPath: "/proc/sys/kernel/osrelease"), encoding: .utf8)
    }

    /// Whether paths are spelled the Windows way: drive letters, backslashes, and a
    /// semicolon-separated search path.
    var usesWindowsPaths: Bool { self == .windows }
}
