import Foundation

/// How a style's TYP can be got at.
enum TypAvailability: Equatable {
    /// An mkgmap `.txt` TYP: readable, and editable in place.
    case source
    /// A compiled `.typ`. Its identity can be read; its contents need a decoder of kmap's
    /// own, since mkgmap compiles in one direction only.
    case binary
    /// The style draws with whatever the device decides.
    case none
}
