import Foundation

/// The JVM's ahead-of-time cache for mkgmap: the classes already loaded and linked, and
/// the profiles its compiler would otherwise gather again on every build. Recorded by the
/// first compile, read by every one after.
///
/// Java 25 and later only: an earlier JVM refuses to start on these options. A cache
/// that does not fit, or is damaged, is passed over by the JVM itself, so a stale one
/// costs the speed and nothing else.
enum JavaWarmStart {
    /// The first Java that keeps method profiles in the cache.
    static let leastMajor = 25
    struct Plan: Equatable {
        /// JVM options, to go before `-jar`.
        var options: [String] = []
        /// Set on the run that records: what it writes, and the cache made from it.
        var recording: URL?
        var cache: URL?
    }

    /// What this run does about the cache: reads it, records one where `recording` is
    /// allowed and there is none, or neither.
    static func plan(java: JavaRuntime, jar: URL, heapGB: Int, recording: Bool) -> Plan {
        guard let major = java.major, major >= leastMajor else { return Plan() }
        let cache = cacheFile(java: java, jar: jar, heapGB: heapGB)
        if FileTools.exists(cache) {
            return Plan(options: quiet + ["-XX:AOTCache=\(cache.path)"])
        }
        guard recording else { return Plan() }
        let record = cache.deletingPathExtension().appendingPathExtension("aotconf")
        return Plan(
            options: quiet + ["-XX:AOTMode=record", "-XX:AOTConfiguration=\(record.path)"],
            recording: record,
            cache: cache
        )
    }

    /// Keeps the JVM's own remarks about the cache out of mkgmap's output.
    private static let quiet = ["-Xlog:aot=off", "-Xlog:cds=off"]

    /// The cache for this JVM, this jar and this heap setting. Any of them changed gives
    /// a new name, so a cache recorded under other conditions is never read: the JVM lays
    /// its objects out differently once the heap asked for is large.
    static func cacheFile(java: JavaRuntime, jar: URL, heapGB: Int) -> URL {
        let stamp = FileTools.modified(of: jar).map { Int($0.timeIntervalSince1970) } ?? 0
        let identity = [
            java.path, java.version, jar.lastPathComponent, String(FileTools.size(of: jar)), String(stamp),
            "heap \(heapGB)"
        ].joined(separator: "\n")
        let key = SHA256.hex(of: Array(identity.utf8)).prefix(16)
        return jar.deletingLastPathComponent().appendingPathComponent("warm-\(key).aot")
    }

    /// The JVM options that turn a recording into the cache, run with the same jar.
    static func assembly(_ plan: Plan, jar: URL, pending: URL) -> [String]? {
        guard let recording = plan.recording else { return nil }
        return quiet + [
            "-XX:AOTMode=create", "-XX:AOTConfiguration=\(recording.path)", "-XX:AOTCache=\(pending.path)",
            "-cp", jar.path
        ]
    }

    /// Caches and recordings in the jar's folder other than `keep`: left by an earlier
    /// jar or Java, or by a run that was stopped.
    static func leftovers(beside jar: URL, keeping keep: URL?) -> [URL] {
        FileTools.contents(of: jar.deletingLastPathComponent()).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("warm-") && name != keep?.lastPathComponent
                && ["aot", "aotconf", "new"].contains($0.pathExtension)
        }
    }

    /// The line a recording JVM prints as it exits, which is not mkgmap's.
    static func isOwnRemark(_ line: String) -> Bool {
        line.contains("AOTConfiguration recorded")
    }
}
