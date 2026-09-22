import Foundation

/// Selection and scroll offset for a vertical list.
struct ListState {
    var selected = 0
    var offset = 0

    /// Moves the selection by `delta`, wrapping round the ends. Page jumps pass
    /// `wrap: false`, which clamps at the ends instead.
    mutating func move(_ delta: Int, count: Int, wrap: Bool = true) {
        guard count > 0 else { selected = 0; offset = 0; return }
        if wrap {
            selected = ((selected + delta) % count + count) % count
        } else {
            selected = max(0, min(count - 1, selected + delta))
        }
    }

    mutating func jump(to index: Int, count: Int) {
        guard count > 0 else { selected = 0; return }
        selected = max(0, min(count - 1, index))
    }

    /// Keeps the selection inside the visible window.
    mutating func clamp(count: Int, visible: Int) {
        guard count > 0, visible > 0 else { selected = 0; offset = 0; return }
        selected = max(0, min(count - 1, selected))
        if selected < offset { offset = selected }
        if selected >= offset + visible { offset = selected - visible + 1 }
        offset = max(0, min(offset, max(0, count - visible)))
    }
}
