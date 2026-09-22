import Foundation

/// Where the pointer was and what it did. Coordinates are the terminal's own, counted
/// from zero at the top-left; screens convert to their own rectangles.
struct MouseEvent: Equatable {
    enum Action: Equatable {
        /// The pointer moved with nothing held down. Reported only while a screen has
        /// motion tracking on.
        case move
        case press, drag, release, scrollUp, scrollDown
    }
    let action: Action
    let x: Int
    let y: Int
    /// Whether the left button was involved; no other button is acted on.
    let isPrimary: Bool
}
