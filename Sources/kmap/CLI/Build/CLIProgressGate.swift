import Foundation

/// Decides which polls of a running stage earn a progress event: its bar moved, the whole
/// build's bar moved, or the stage said something new about what it is doing. The last
/// matters for work with no percentage, where the detail line is the only sign of life.
extension CLI {
    struct ProgressGate {
        /// A bar has moved once it has gained a whole percent.
        static let visibleStep = 0.01

        private var lastOverall = -1.0
        private var lastFraction: [String: Double] = [:]
        private var lastDetail: [String: String] = [:]

        mutating func speaks(
            stage id: String,
            fraction: Double?,
            overall: Double,
            detail: String
        ) -> Bool {
            let moved = abs((fraction ?? 0) - (lastFraction[id] ?? -1)) >= Self.visibleStep
            let grew = abs(overall - lastOverall) >= Self.visibleStep
            let said = detail != lastDetail[id]
            guard moved || grew || said else { return false }
            lastFraction[id] = fraction ?? 0
            lastDetail[id] = detail
            lastOverall = overall
            return true
        }
    }
}
