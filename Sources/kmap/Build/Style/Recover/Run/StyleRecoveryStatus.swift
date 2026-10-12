import Foundation

extension StyleRecovery {
    enum Status: String {
        /// Two or more agreeing identifications, and a rule line found: in the sheet.
        case resolved
        /// One clean identification: in the sheet, flagged for review.
        case singleWitness = "single-witness"
        /// Witnesses agree but no default rule emits this meaning; decided by hand.
        case noRule = "no-rule"
        /// Witnesses disagree beyond the threshold; decided by hand.
        case mixed
        /// Nothing identified on the ground that was searched.
        case noEvidence = "no-evidence"
    }
}
