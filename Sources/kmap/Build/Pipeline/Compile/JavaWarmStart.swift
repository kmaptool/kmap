import Foundation

/// The JVM's ahead-of-time cache for mkgmap: the classes already loaded and linked, and
/// the profiles its compiler would otherwise gather again on every build. Recorded by the
/// first compile, read by every one after.
///
/// Java 25 and later only: an earlier JVM refuses to start on these options. A cache
/// that does not fit, or is damaged, is passed over by the JVM itself: it costs the
/// speed and nothing else, and the key changes with whatever makes it not fit.
enum JavaWarmStart {
    /// The first Java that keeps method profiles in the cache.
    static let leastMajor = 25
    /// A cache or a refusal untouched for this long belongs to no build still running.
    /// A cache is touched each time it is read, so this counts from its last use.
    static let staleAfter: TimeInterval = 86400
    /// The same for a recording and what is assembled from it: a JVM writes its recording
    /// only as it exits, and the cache is assembled straight after, so an hour-old one was
    /// left by a run that stopped.
    static let recordingStaleAfter: TimeInterval = 3600

    /// Where the caches live: kmap's own folder, not the jar's, which may be one the user
    /// pointed at and kmap cannot write to.
    static var directory: URL { Paths.cache.appendingPathComponent("warm-start", isDirectory: true) }

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
    static func plan(
        java: JavaRuntime,
        jar: URL,
        heapGB: Int,
        recording: Bool,
        in directory: URL = directory
    ) -> Plan {
        // OpenJ9 knows none of these options, and may refuse to start on them.
        guard let major = java.major, major >= leastMajor, !java.isOpenJ9 else { return Plan() }
        let cache = cacheFile(java: java, jar: jar, heapGB: heapGB, in: directory)
        if FileTools.exists(cache) {
            // Touched on reading, so the cleanup counts from its last use.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
            return Plan(options: quiet + ["-XX:AOTCache=\(cache.path)"], cache: cache)
        }
        // A JVM that failed to record under this key is not asked to again until the mark
        // goes stale.
        if let refused = FileTools.modified(of: refusal(of: cache)), Date().timeIntervalSince(refused) <= staleAfter {
            return Plan(cache: cache)
        }
        guard recording else { return Plan(cache: cache) }
        Paths.ensure(directory)
        let run = UUID().uuidString.prefix(8).lowercased()
        let record = directory.appendingPathComponent(
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

    /// The cache for this JVM with its options, this jar and this heap setting. Any of
    /// them changed gives a new name, so a cache recorded under other conditions is never
    /// read: the JVM lays its objects out differently once the heap asked for is large.
    /// The name starts with the jar's own key, so its caches can be told apart.
    static func cacheFile(
        java: JavaRuntime,
        jar: URL,
        heapGB: Int,
        in directory: URL = directory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // Through a link to the file itself, which is what changes when mkgmap is replaced.
        let target = FileTools.resolvingLinks(jar)
        let stamp = FileTools.modified(of: target).map { Int($0.timeIntervalSince1970) } ?? 0
        // The JVM itself, where a link names it: a rebuilt JVM under the same name and
        // version refuses a cache the old one made, and says nothing with the log off.
        let binary = FileTools.resolvingLinks(URL(fileURLWithPath: java.path))
        let built = FileTools.modified(of: binary).map { Int($0.timeIntervalSince1970) } ?? 0
        // The options the JVM takes from the environment too: they change its layout as
        // the command line does.
        // Matched without case: Windows names its variables so, and the JVM reads them so.
        let fromEnvironment = ["JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS"].map { name in
            environment.first { $0.key.uppercased() == name }?.value ?? ""
        }
        let identity =
            ([
                java.path, binary.path, String(built), java.version, java.options.joined(separator: " "),
                jar.standardizedFileURL.path, String(FileTools.size(of: target)), String(stamp), "heap \(heapGB)"
            ] + fromEnvironment).joined(separator: "\n")
        let key = SHA256.hex(of: Array(identity.utf8)).prefix(16)
        return directory.appendingPathComponent("\(prefix(of: jar))\(key).aot")
    }

    /// The start of every cache and recording name made for `jar`.
    private static func prefix(of jar: URL) -> String {
        "warm-\(SHA256.hex(of: Array(jar.standardizedFileURL.path.utf8)).prefix(8))-"
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

    /// Caches, refusals and recordings other than `keep`, gone stale: left by an earlier
    /// jar or Java, or by a run that was stopped. A younger one may be another build's,
    /// still in use.
    static func leftovers(keeping keep: URL?, in directory: URL = directory, now: Date = Date()) -> [URL] {
        FileTools.contents(of: directory).filter {
            guard isOurs($0), $0.lastPathComponent != keep?.lastPathComponent,
                let touched = FileTools.modified(of: $0)
            else { return false }
            let recorded = ["aotconf", "new"].contains($0.pathExtension)
            return now.timeIntervalSince(touched) > (recorded ? recordingStaleAfter : staleAfter)
        }
    }

    /// The options of a run that only asks mkgmap its version, recording as `plan` would,
    /// into a file of its own: whether this JVM records at all, known in a moment.
    static func probe(_ plan: Plan, jar: URL, heapGB: Int) -> (options: [String], recording: URL)? {
        guard let recording = plan.recording else { return nil }
        let trial = recording.deletingPathExtension().appendingPathExtension("trial.aotconf")
        let options = plan.options.map {
            $0 == "-XX:AOTConfiguration=\(recording.path)" ? "-XX:AOTConfiguration=\(trial.path)" : $0
        }
        return (options + ["-Xmx\(heapGB)g", "-jar", jar.path, "--version"], trial)
    }

    /// Removes every cache and recording made for `jar`: called when it is replaced or
    /// removed, after which none of them fits anything.
    static func forgetAll(for jar: URL, in directory: URL = directory) {
        let start = prefix(of: jar)
        for file in FileTools.contents(of: directory) where isOurs(file) && file.lastPathComponent.hasPrefix(start) {
            FileTools.removeIfPresent(file)
        }
    }

    /// The mark of a key whose recording failed a compile.
    static func refusal(of cache: URL) -> URL {
        cache.deletingPathExtension().appendingPathExtension("refused")
    }

    /// Marks the plan's key as one this JVM cannot record under.
    static func refuse(_ plan: Plan) {
        guard let cache = plan.cache else { return }
        try? FileTools.write(Data(), to: refusal(of: cache))
    }

    /// Removes a recording and what was assembled from it, whatever became of the run.
    static func discard(_ plan: Plan) {
        guard let recording = plan.recording else { return }
        FileTools.removeIfPresent(recording)
        FileTools.removeIfPresent(pending(for: recording))
    }

    private static func isOurs(_ file: URL) -> Bool {
        file.lastPathComponent.hasPrefix("warm-") && ["aot", "aotconf", "new", "refused"].contains(file.pathExtension)
    }

    /// The line a recording JVM prints as it exits, which is not mkgmap's.
    static func isOwnRemark(_ line: String) -> Bool {
        line.contains("AOTConfiguration recorded")
    }
}
