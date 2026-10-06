import Foundation

extension CoarseEvidence {
    /// A point named by its place: the element, and the way standing there.
    struct Rescue: Sendable {
        let at: Int
        let kind: ElementDumper.Kind
        let type: Int
        let way: Int64
        let tags: [String: String]
    }
}
