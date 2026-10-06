import Foundation

extension GEDTM30 {
    /// The first image's tags, their values fetched as they are asked for.
    struct Directory {
        /// A tag read whole is short; a longer one means a damaged header.
        private static let longestValue = 65536
        /// More entries than this is not a directory.
        private static let mostEntries = 1000
        /// More tiles than this is not an index.
        private static let mostTiles = 1 << 24

        let order: TIFF.Order
        private let read: Read
        private let table: Data
        /// Bytes of an entry's field: the value itself when it fits, else its offset.
        private let fieldSize: Int
        private let entries: [Int: (type: Int, count: Int, field: Int)]

        init(read: @escaping Read) async throws {
            let head = try await read(0, 16)
            guard head.count >= 16, let bigEndian = TIFF.isBigEndian(head[head.startIndex], head[head.startIndex + 1])
            else { throw Trouble.notTIFF }
            let order = TIFF.Order(bigEndian: bigEndian)
            let version = order.int(head, 2, 2)
            guard version == TIFF.classic || version == TIFF.big else { throw Trouble.notTIFF }
            let big = version == TIFF.big
            let at = Int64(big ? order.int(head, 8, 8) : order.int(head, 4, 4))
            // Past the largest file there can be, the sums below overflow.
            guard (0...GEDTM30.mostFileBytes).contains(at) else { throw Trouble.notTIFF }
            let countSize = big ? 8 : 2, entrySize = big ? 20 : 12
            let count = order.int(try await read(at, countSize), 0, countSize)
            guard count > 0, count < Self.mostEntries else { throw Trouble.notTIFF }
            let table = try await read(at + Int64(countSize), count * entrySize)
            guard table.count == count * entrySize else { throw Trouble.notTIFF }

            var entries: [Int: (type: Int, count: Int, field: Int)] = [:]
            for i in 0..<count {
                let entry = i * entrySize
                entries[order.int(table, entry, 2)] = (
                    order.int(table, entry + 2, 2),
                    order.int(table, entry + 4, big ? 8 : 4),
                    entry + (big ? 12 : 8)
                )
            }
            self.order = order
            self.read = read
            self.table = table
            self.entries = entries
            fieldSize = big ? 8 : 4
        }

        /// The value's bytes, inline or fetched from where the field points.
        private func raw(_ tag: Int) async throws -> (type: Int, count: Int, data: Data)? {
            guard let entry = entries[tag] else { return nil }
            guard entry.count >= 0, entry.count <= Self.longestValue else { throw Trouble.notTIFF }
            let length = TIFF.size(ofType: entry.type) * entry.count
            let data =
                length <= fieldSize
                ? table.subdata(in: (table.startIndex + entry.field)..<(table.startIndex + entry.field + length))
                : try await read(Int64(order.int(table, entry.field, fieldSize)), length)
            guard data.count >= length else { throw Trouble.notTIFF }
            return (entry.type, entry.count, data)
        }

        func numbers(_ tag: Int) async throws -> [Double] {
            guard let (type, count, data) = try await raw(tag) else { return [] }
            let size = TIFF.size(ofType: type)
            return (0..<count).compactMap { order.number(data, $0 * size, type: type) }
        }

        /// A whole number; `fallback` where the file has no such tag.
        func one(_ tag: Int, _ fallback: Int? = nil) async throws -> Int {
            if let value = try await numbers(tag).first {
                guard let whole = Int(exactly: value) else { throw Trouble.notTIFF }
                return whole
            }
            guard let fallback else { throw Trouble.unsupported("no tag \(tag)") }
            return fallback
        }

        /// A text tag up to its first 0 byte, trimmed.
        func text(_ tag: Int) async throws -> String? {
            guard let (_, _, data) = try await raw(tag) else { return nil }
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        /// Where a tile index starts, its entry size and count. Too long to fetch whole.
        func index(_ tag: Int) throws -> (at: Int64, size: Int, count: Int) {
            guard let entry = entries[tag], entry.type == TIFF.FieldType.long || entry.type == TIFF.FieldType.long8
            else { throw Trouble.unsupported("tile index tag \(tag)") }
            guard entry.count > 1, entry.count <= Self.mostTiles else { throw Trouble.unsupported("tile count") }
            return (Int64(order.int(table, entry.field, fieldSize)), TIFF.size(ofType: entry.type), entry.count)
        }
    }
}
