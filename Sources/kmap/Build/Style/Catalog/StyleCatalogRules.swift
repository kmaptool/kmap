import Foundation

/// The rule text a materialized style is shaped from: a zoom plan's mark on its identity,
/// and blocks spliced in.
extension StyleCatalog {
    /// What a zoom plan adds to the materialized style's identity: the windows, not the
    /// plan's name - two plans with the same windows produce the same rules.
    func zoomTag(_ plan: ZoomPlan) -> String {
        guard plan.movesAnything else { return "" }
        let windows = plan.windows.sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value.rungs.lowerBound)-\($0.value.rungs.upperBound)" }
        return "+zoom-" + windows.joined(separator: ",")
    }

    /// Inserts a block of rules ahead of `<finalize>`, or appends it where there is none.
    /// A `<finalize>` section may hold only actions; a type definition after it is an error.
    func splice(_ rules: String, into text: inout String) {
        if let finalize = text.range(of: "\n<finalize>") {
            text.replaceSubrange(finalize, with: rules + "\n<finalize>")
        } else {
            text += rules
        }
    }
}
