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
    /// A cache or a recording untouched for this long belongs to no build still running.
    static let staleAfter: TimeInterval = 86400

    struct Plan: Equatable {
        /// JVM options, to go before `-jar`.
        var options: [String] = []
        /// Set on the run that records: what it writes, under a name of this run's own,
        /// so that 2 builds recording at once do not write the same file.
        var recording: URL?
        /// The cache this JVM, jar and heap go by; nil where the JVM takes none.
        var cache: URL?
    }

    /// What this run does about the cache: reads it, records one where `recording` is
    /// allowed and there is none, or neither.
    static func plan(java: JavaRuntime, jar: URL, heapGB: Int, recording: Bool) -> Plan {
        guard let major = java.major, major >= leastMajor else { return Plan() }
        let cache = cacheFile(java: java, jar: jar, heapGB: heapGB)
        if FileTools.exists(cache) {
            return Plan(options: quiet + ["-XX:AOTCache=\(cache.path)"], cache: cache)
        }
        guard recording else { return Plan(cache: cache) }
        let run = UUID().uuidString.prefix(8).lowercased()
        let record = cache.deletingLastPathComponent().appendingPathComponent(
            "\(cache.deletingPathExtension().lastPathComponent)-\(run).aotconf"
        )
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

    /// Where a recording run assembles its cache before it takes the cache's name.
    static func pending(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("new")
    }

    /// The JVM options that turn a recording into the cache, run with the same jar and
    /// the same heap: a cache assembled under another heap is refused where the 2 lay
    /// objects out differently.
    static func assembly(_ plan: Plan, jar: URL, heapGB: Int) -> [String]? {
        guard let recording = plan.recording else { return nil }
        return quiet + [
            "-Xmx\(heapGB)g", "-XX:AOTMode=create", "-XX:AOTConfiguration=\(recording.path)",
            "-XX:AOTCache=\(pending(for: recording).path)", "-cp", jar.path
        ]
    }

    /// Caches and recordings in the jar's folder other than `keep`, untouched for
    /// `staleAfter`: left by an earlier jar or Java, or by a run that was stopped. A
    /// younger one may be another build's, still being written.
    static func leftovers(beside jar: URL, keeping keep: URL?, now: Date = Date()) -> [URL] {
        FileTools.contents(of: jar.deletingLastPathComponent()).filter {
            let name = $0.lastPathComponent
            guard name.hasPrefix("warm-"), name != keep?.lastPathComponent,
                ["aot", "aotconf", "new"].contains($0.pathExtension),
                let touched = FileTools.modified(of: $0)
            else { return false }
            return now.timeIntervalSince(touched) > staleAfter
        }
    }

    /// Removes every cache and recording beside `jar`: called when a jar there is
    /// replaced or removed, after which none of them fits anything.
    static func forgetAll(beside jar: URL) {
        for file in FileTools.contents(of: jar.deletingLastPathComponent())
        where file.lastPathComponent.hasPrefix("warm-") && ["aot", "aotconf", "new"].contains(file.pathExtension) {
            FileTools.removeIfPresent(file)
        }
    }

    /// The line a recording JVM prints as it exits, which is not mkgmap's.
    static func isOwnRemark(_ line: String) -> Bool {
        line.contains("AOTConfiguration recorded")
    }
}
