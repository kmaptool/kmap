import Foundation

extension StyleRecovery {
    /// What one foreign code's witnesses meant, before anything has been decided.
    struct CodeReading {
        let key: String
        let code: Evidence.ForCode
        let buckets: [String: MeaningBucket]
        /// Witnesses that meant anything at all.
        let meant: Int
        /// Whether the code is absent from the default rules. A default code writes
        /// nothing to the sheet, but its witnesses still count towards which code
        /// owns a meaning.
        let foreign: Bool

        /// The noise floor for this code: below it a meaning is a side-tag, not a claim.
        var floor: Int { max(fewestWitnesses, Int(Double(meant) * noise)) }
    }
}
