import Foundation

extension RepairPlanner {
    /// What the pass decided about a gap. Verdicts are counted by name, and the counts are
    /// what the build log prints.
    enum Verdict {
        static let building = "building", fence = "fence"
        static let joined = "joined"
        static let alreadyJoined = "already joined nearby"
        static let sameNode = "already the same node"
        static let alongside = "running alongside"
        static let wouldPull = "would pull another line off course"
        static func extended(_ what: String) -> String { "extended off the \(what)" }
        static let deadEnd = "a dead end, noexit=yes"

        static func stoppedBy(_ what: String) -> String { "stopped by \(what)" }
        static func tooHigh(_ what: String, _ metres: Double) -> String {
            "stopped by \(what) over \(Int(metres)) m high"
        }
        static func bridged(_ what: String) -> String { "bridged over \(what.isEmpty ? "an obstacle" : what)" }
    }
}
