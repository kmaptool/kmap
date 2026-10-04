import Foundation

/// A JVM that starts, and the options it needs to start.
///
/// A JVM can be installed and still fail during VM initialization, when the reservation
/// of compressed class space cannot be satisfied; the heap size is unrelated. Options are
/// probed rather than assumed: a plain start first, a retry with the feature off second.
struct JavaRuntime: Equatable {
    let path: String
    let version: String
    /// Options this machine's JVM needs before it will start at all. Empty almost
    /// everywhere.
    let options: [String]

    /// The feature release: 21 of `openjdk version "21.0.4"`, 8 of `"1.8.0_292"`. Nil
    /// where the version line names none.
    var major: Int? {
        guard let open = version.firstIndex(of: "\"") else { return nil }
        let quoted = version[version.index(after: open)...].prefix { $0 != "\"" }
        let parts = quoted.split { !$0.isNumber }.compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        return first == 1 ? parts.dropFirst().first : first
    }

    /// `arguments`, with whatever this JVM needs in front of them. JVM options have to
    /// precede `-jar`, which is why this prepends rather than appends.
    func command(_ arguments: [String]) -> [String] { options + arguments }

    /// The same, for the tools that take JVM options only through `-J`.
    var toolOptions: [String] { options.map { "-J" + $0 } }

    /// Whether this is a whole JDK rather than a runtime: `javac` and `jar` stand beside
    /// it. Maps build without them; the seam patch is compiled with both.
    var isKit: Bool {
        FileTools.isExecutable(ToolLocations.companion("javac", of: path))
            && FileTools.isExecutable(ToolLocations.companion("jar", of: path))
    }
}
