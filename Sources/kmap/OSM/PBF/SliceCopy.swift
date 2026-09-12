import Foundation

extension ArraySlice {
    /// A copy holding exactly these elements, with capacity to match. `Array(slice)` may
    /// instead hand back the source buffer, carrying a scratch array's full grown
    /// capacity.
    var exactly: [Element] {
        [Element](unsafeUninitializedCapacity: count) { out, made in
            _ = out.initialize(fromContentsOf: self)
            made = count
        }
    }
}
