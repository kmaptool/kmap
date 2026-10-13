import Foundation

extension StyleRecovery {
    /// One rule line, and every foreign code laying claim to it. A style painting a
    /// road as casing, fill and a low-zoom stroke has 3 codes for 1 rule, and
    /// all 3 belong in the sheet as layers.
    struct ClaimedRule {
        let lines: [DefaultRuleBook.Line]
        var codes: [CodeClaim] = []
    }

    /// 1 code's claim on a rule: how much it drew there, on which elements, under which
    /// tags and at which zooms.
    typealias CodeClaim = (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int], resolutions: [Int: Int])
}
