import Foundation

extension StyleRecovery {
    /// A rule the style does not have, to be written for a code that needs one.
    struct RuleAddition {
        let tag: String
        let key: String
        let type: Int
        let witnesses: Int
        /// The elements it was seen on: for 1 tag, the same elements are 2
        /// layers and different ones are 2 kinds.
        let ids: Set<Int64>
        /// The zooms the code was seen drawn at, so a rule written for it draws
        /// where its author drew it rather than at every zoom below.
        var resolutions: [Int: Int] = [:]
        /// Written with `& building!=*`: their map draws the buildings carrying this
        /// tag as buildings, and only the open ground this way.
        var openOnly = false
    }
}
