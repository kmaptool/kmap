import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// Finds the external programs kmap needs, and installs the ones it can.
/// Shared by the interface and every task of a build. `@unchecked Sendable` stands on
/// `cacheLock`: the probe caches are the only state that changes, and they are read and
/// written only under it.
final class Toolchain: @unchecked Sendable {
    let settings: SettingsStore
    init(settings: SettingsStore) { self.settings = settings }

    // MARK: Probe cache
    //
    // A probe runs an external program to read its version, so each answer is held until
    // `invalidate` is called rather than recomputed from the render loop.

    let cacheLock = NSLock()
    var javaCache: JavaRuntime??
    var kitCache: JavaRuntime??
    var mkgmapCache: (url: URL, version: String)??
    var pyhgtmapCache: (url: URL, version: String)??
    var statusCache: [ToolStatus]?

    /// Discards every cached probe. Call after an install or a requested refresh.
    func invalidate() {
        cacheLock.lock()
        javaCache = nil
        kitCache = nil
        mkgmapCache = nil
        pyhgtmapCache = nil
        statusCache = nil
        cacheLock.unlock()
        Archive.forget()
    }

    /// True once a probe has run.
    var hasProbed: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return statusCache != nil
    }

    func cached<T>(
        _ keyPath: ReferenceWritableKeyPath<Toolchain, T??>,
        compute: () -> T?
    ) -> T? {
        cacheLock.lock()
        if let hit = self[keyPath: keyPath] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        // Computed outside the lock: these spawn processes.
        let value = compute()

        cacheLock.lock()
        self[keyPath: keyPath] = .some(value)
        cacheLock.unlock()
        return value
    }

    // MARK: Installation

    enum InstallError: Error, LocalizedError {
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let m): return m
            case .failed(let m): return m
            }
        }
    }

    /// Every tool id `install` accepts. Listed rather than derived from `status()`, which
    /// reports only what is missing on this machine and so cannot validate a name.
    static let installableIDs =
        ["mkgmap", "mkgmap-patch", "pyhgtmap"]
        + DataPack.all.map(\.id) + ["java", "python", "unzip"]
}
