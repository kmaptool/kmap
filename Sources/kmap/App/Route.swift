import Foundation

/// What a screen wants the navigator to do after handling a key.
enum Route {
    case none
    case push(Screen)
    case pop
    case popToRoot
    case replace(Screen)
    case quit
}
