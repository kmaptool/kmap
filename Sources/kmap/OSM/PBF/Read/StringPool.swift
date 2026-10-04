import Foundation

/// A block's string table. An entry is decoded to a Swift string on first request and
/// cached; the table is held once per block and shared by reference.
final class StringPool {
    private let raw: [UnsafeRawBufferPointer]
    private var made: [String?]

    init(_ raw: [UnsafeRawBufferPointer]) {
        self.raw = raw
        made = [String?](repeating: nil, count: raw.count)
    }

    var count: Int { raw.count }

    func text(_ index: Int) -> String {
        guard index >= 0 && index < raw.count else { return "" }
        if let known = made[index] { return known }
        let word = String(decoding: raw[index], as: UTF8.self)
        made[index] = word
        return word
    }

    /// Returns every entry, decoding those not decoded yet.
    func all() -> [String] {
        (0..<raw.count).map { text($0) }
    }

    /// Returns an entry's raw bytes, for comparison without building a String.
    func bytes(_ index: Int) -> UnsafeRawBufferPointer? {
        guard index >= 0 && index < raw.count else { return nil }
        return raw[index]
    }
}
