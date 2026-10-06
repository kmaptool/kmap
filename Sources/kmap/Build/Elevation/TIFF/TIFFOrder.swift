import Foundation

extension TIFF {
    /// Integers out of a file in its own byte order.
    struct Order: Sendable {
        let bigEndian: Bool

        /// `width` bytes at `at`, counted from the start of `data`; 0 past its end.
        func word(_ data: Data, _ at: Int, _ width: Int) -> UInt64 {
            data.withUnsafeBytes { raw in
                guard at >= 0, at + width <= raw.count else { return 0 }
                var value: UInt64 = 0
                for i in 0..<width {
                    value = value << 8 | UInt64(raw[at + (bigEndian ? i : width - 1 - i)])
                }
                return value
            }
        }

        func int(_ data: Data, _ at: Int, _ width: Int) -> Int {
            Int(truncatingIfNeeded: word(data, at, width))
        }

        /// 1 value of a field type as a number; nil for the types not read: text,
        /// rationals and signed integers.
        func number(_ data: Data, _ at: Int, type: Int) -> Double? {
            switch type {
            case FieldType.byte, FieldType.short, FieldType.long, FieldType.long8:
                Double(word(data, at, TIFF.size(ofType: type)))
            case FieldType.float: Double(Float(bitPattern: UInt32(truncatingIfNeeded: word(data, at, 4))))
            case FieldType.double: Double(bitPattern: word(data, at, 8))
            default: nil
            }
        }
    }
}
