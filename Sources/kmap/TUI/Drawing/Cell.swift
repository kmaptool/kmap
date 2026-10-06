import Foundation

/// One character on screen, in one style.
struct Cell: Equatable {
    var ch: Character = " "
    var style: Style = .plain
}
