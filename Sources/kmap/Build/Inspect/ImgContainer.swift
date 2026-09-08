import Foundation

/// A minimal reader for the FAT-like filesystem inside a Garmin `.img`, used to reach the
/// embedded `.TYP`. The `DSKIMG` signature sits at 0x10, block size is
/// `1 << (byte[0x61] + byte[0x62])`, and the directory starts at `byte[0x40] × 512` — fixed
/// 512-byte sectors, not blocks.
enum ImgContainer {

    struct SubFile {
        let name: String
        let ext: String
        let size: Int
        var blocks: [Int]
        let blockSize: Int

        var fullName: String { "\(name).\(ext)" }
    }

    private static let signatureOffset = 0x10
    private static let blockExponent1 = 0x61
    private static let blockExponent2 = 0x62
    private static let directorySectorOffset = 0x40
    private static let directoryEntrySize = 512

    /// True where the file carries the `DSKIMG` signature. Reads only the first sector.
    static func isImg(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x200),
              head.count > signatureOffset + 6 else { return false }
        return head[signatureOffset..<(signatureOffset + 6)].elementsEqual(Array("DSKIMG".utf8))
    }

    /// Parses the header and directory. Reads a few kilobytes, not the whole file.
    static func directory(of url: URL) -> [SubFile] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x600), head.count >= 0x600 else { return [] }
        let bytes = [UInt8](head)
        guard bytes.count > signatureOffset + 6,
              Array(bytes[signatureOffset..<(signatureOffset + 6)]) == Array("DSKIMG".utf8) else {
            return []
        }

        let blockSize = 1 << (Int(bytes[blockExponent1]) + Int(bytes[blockExponent2]))
        guard blockSize > 0, blockSize <= 1 << 20 else { return [] }

        let directoryStart = Int(bytes[directorySectorOffset] == 0 ? 2 : bytes[directorySectorOffset])
            * directoryEntrySize
        guard (try? handle.seek(toOffset: UInt64(directoryStart))) != nil else { return [] }

        // The first entry describes the directory itself; its block list bounds the FAT.
        var directoryEnd: Int? = nil
        if let selfEntry = try? handle.read(upToCount: directoryEntrySize),
           selfEntry.count == directoryEntrySize, selfEntry.first == 1 {
            let blocks = blockList(in: [UInt8](selfEntry))
            if let last = blocks.max() { directoryEnd = (last + 1) * blockSize }
        }

        var order: [String] = []
        var found: [String: SubFile] = [:]

        while true {
            let position = Int((try? handle.offset()) ?? 0)
            if let directoryEnd, position >= directoryEnd { break }
            guard let raw = try? handle.read(upToCount: directoryEntrySize),
                  raw.count == directoryEntrySize, raw.first == 1 else { break }

            let entry = [UInt8](raw)
            // `CodePage.latin1` rather than Foundation's Latin-1, which is not dependable
            // off Apple's platforms: it decodes a short buffer and returns nil for a large
            // one. These two are short and would survive, but the habit is what matters —
            // the same call on a 40 kB page is what broke every elevation download.
            let name = CodePage.latin1(entry[1..<9]).trimmingCharacters(in: .whitespaces)
            let ext = CodePage.latin1(entry[9..<12]).trimmingCharacters(in: .whitespaces)
            let size = Int(UInt32(entry[0x0C]) | UInt32(entry[0x0D]) << 8
                           | UInt32(entry[0x0E]) << 16 | UInt32(entry[0x0F]) << 24)
            let blocks = blockList(in: entry)
            let key = "\(name).\(ext)"

            if found[key] != nil {
                found[key]?.blocks.append(contentsOf: blocks)
            } else {
                found[key] = SubFile(name: name, ext: ext, size: size,
                                     blocks: blocks, blockSize: blockSize)
                order.append(key)
            }
        }

        return order.compactMap { found[$0] }.filter { !$0.name.isEmpty }
    }

    private static func blockList(in entry: [UInt8]) -> [Int] {
        let count = (directoryEntrySize - 0x20) / 2
        var blocks: [Int] = []
        blocks.reserveCapacity(count)
        for i in 0..<count {
            let offset = 0x20 + i * 2
            guard offset + 1 < entry.count else { break }
            let value = Int(entry[offset]) | Int(entry[offset + 1]) << 8
            if value == 0xFFFF { continue }
            blocks.append(value)
        }
        return blocks
    }

    /// Reads `length` bytes of a subfile, walking its block list.
    static func read(_ file: SubFile, from url: URL, offset: Int = 0, length: Int? = nil) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var remaining = min(length ?? (file.size - offset), max(0, file.size - offset))
        var cursor = offset
        var out = Data()
        // Reserved against the block list rather than the declared 32-bit size, which a
        // corrupt container can set to four gigabytes.
        let plausible = file.blocks.count * file.blockSize
        out.reserveCapacity(min(remaining, max(0, plausible)))

        while remaining > 0 {
            let blockIndex = cursor / file.blockSize
            let within = cursor % file.blockSize
            guard blockIndex < file.blocks.count else { break }
            let take = min(file.blockSize - within, remaining)
            let position = file.blocks[blockIndex] * file.blockSize + within
            guard (try? handle.seek(toOffset: UInt64(position))) != nil,
                  let chunk = try? handle.read(upToCount: take), !chunk.isEmpty else { break }
            out.append(chunk)
            cursor += chunk.count
            remaining -= chunk.count
        }
        return out.isEmpty ? nil : out
    }

    /// The TYP subfile inside this map, or nil where there is none.
    static func typSubFile(in url: URL) -> SubFile? {
        directory(of: url).first { $0.ext.uppercased() == "TYP" }
    }

    /// Reads the embedded TYP's identity without extracting it: the `GARMIN TYP` signature at
    /// offset 2, family id at 0x2F and product id at 0x31, both little-endian 16-bit.
    static func typIdentity(in url: URL) -> (familyID: Int, productID: Int, size: Int)? {
        guard let sub = typSubFile(in: url),
              let head = read(sub, from: url, offset: 0, length: 0x40),
              head.count >= 0x33 else { return nil }
        let bytes = [UInt8](head)
        guard bytes.count > 12,
              Array(bytes[2..<12]) == Array("GARMIN TYP".utf8) else { return nil }
        let family = Int(bytes[0x2F]) | Int(bytes[0x30]) << 8
        let product = Int(bytes[0x31]) | Int(bytes[0x32]) << 8
        guard family > 0 else { return nil }
        return (family, max(1, product), sub.size)
    }

    /// Extracts the embedded TYP to `destination`. Returns false where there is none.
    @discardableResult
    static func extractTYP(from url: URL, to destination: URL) -> Bool {
        guard let sub = typSubFile(in: url),
              let data = read(sub, from: url), data.count > 0x33 else { return false }
        Paths.ensure(destination.deletingLastPathComponent())
        return (try? data.write(to: destination, options: .atomic)) != nil
    }
}
