import Foundation

/// What a surface had to cut short, for the tests that check every language fits.
extension Surface {
    /// A string the renderer had to cut short, with the position it was drawn at.
    /// Collected only inside `collectClipped(_:)`.
    struct Clip: Hashable {
        let x: Int, y: Int
        let text: String
        /// Identity is the position alone, so the same draw call compares equal across
        /// languages.
        static func == (a: Clip, b: Clip) -> Bool { a.x == b.x && a.y == b.y }
        func hash(into hasher: inout Hasher) { hasher.combine(x); hasher.combine(y) }
    }

    /// Nil except while something is collecting.
    private static let clips = Locked<[Clip]?>(nil)

    static func collectClipped<T>(_ body: () throws -> T) rethrows -> (T, [Clip]) {
        clips.withLock { $0 = [] }
        defer { clips.withLock { $0 = nil } }
        let out = try body()
        return (out, clips.withLock { $0 ?? [] })
    }

    static func noteClipped(at x: Int, _ y: Int, _ string: String) {
        guard !string.isEmpty else { return }
        clips.withLock { $0?.append(Clip(x: x, y: y, text: string)) }
    }
}
