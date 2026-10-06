import Foundation

/// A minimal reader for the FAT-like filesystem inside a Garmin `.img`, used to reach the
/// embedded `.TYP`. The `DSKIMG` signature sits at 0x10, block size is
/// `1 << (byte[0x61] + byte[0x62])`, and the directory starts at `byte[0x40] * 512`: fixed
/// 512-byte sectors, not blocks.
enum ImgContainer {
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
            head.count > signatureOffset + 6
        else { return false }
        return head[signatureOffset..<(signatureOffset + 6)].elementsEqual(Array("DSKIMG".utf8))
    }

    /// Parses the header and directory. Reads a few kilobytes, not the whole file.
    static func directory(of url: URL) -> [SubFile] {
        layout(of: url)?.files ?? []
    }

    /// The subfiles that start with a header of their own, `GARMIN` at byte 2.
    private static let headed: Set<String> = ["TRE", "RGN", "LBL", "NET", "NOD", "DEM", "MDR", "SRT", "TYP"]

    private static let mostDirectoryBytes = 64 << 20

    /// Whether every block the directory lists is in the file and, with `headers`, each map
    /// subfile starts with its header and the directory with its own entry, written last:
    /// mkgmap does not report a full disk on its last write. A locked map has no readable
    /// headers.
    static func isWhole(_ url: URL, headers: Bool = true) -> Bool {
        guard let layout = layout(of: url), !layout.files.isEmpty else { return false }
        guard !headers || layout.directoryEnd != nil else { return false }
        let length = Int(FileTools.size(of: url))
        guard layout.directoryEnd.map({ $0 <= length }) ?? true,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        for file in layout.files {
            let used = (file.size + file.blockSize - 1) / file.blockSize
            guard used <= file.blocks.count else { return false }
            for (index, block) in file.blocks.prefix(used).enumerated() {
                let tail = index == used - 1 ? (file.size - 1) % file.blockSize + 1 : file.blockSize
                guard block * file.blockSize + tail <= length else { return false }
            }
            guard headers, file.size >= 9, headed.contains(file.ext.uppercased()), let first = file.blocks.first else {
                continue
            }
            guard (try? handle.seek(toOffset: UInt64(first * file.blockSize))) != nil,
                let head = try? handle.read(upToCount: 9), head.count == 9,
                head[head.startIndex + 2..<head.startIndex + 9].elementsEqual("GARMIN ".utf8)
            else { return false }
        }
        return true
    }

    private static func layout(of url: URL) -> (files: [SubFile], directoryEnd: Int?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x600), head.count >= 0x600 else { return nil }
        let bytes = [UInt8](head)
        guard bytes.count > signatureOffset + 6,
            Array(bytes[signatureOffset..<(signatureOffset + 6)]) == Array("DSKIMG".utf8)
        else {
            return nil
        }

        let blockSize = 1 << (Int(bytes[blockExponent1]) + Int(bytes[blockExponent2]))
        guard blockSize > 0, blockSize <= 1 << 20 else { return nil }

        let directoryStart =
            Int(bytes[directorySectorOffset] == 0 ? 2 : bytes[directorySectorOffset])
            * directoryEntrySize
        guard (try? handle.seek(toOffset: UInt64(directoryStart))) != nil else { return nil }

        // The first entry describes the directory itself; its block list bounds the FAT.
        var directoryEnd: Int? = nil
        if let selfEntry = try? handle.read(upToCount: directoryEntrySize),
            selfEntry.count == directoryEntrySize, selfEntry.first == 1
        {
            let blocks = blockList(in: [UInt8](selfEntry))
            if let last = blocks.max() { directoryEnd = (last + 1) * blockSize }
        }

        var order: [String] = []
        var found: [String: SubFile] = [:]
        // A directory is megabytes at most, a map of thousands of tiles included: a damaged
        // self entry claiming more is not walked through the whole file.
        let walkStart = Int((try? handle.offset()) ?? 0)

        while true {
            let position = Int((try? handle.offset()) ?? 0)
            if let directoryEnd, position >= directoryEnd { break }
            if position - walkStart >= Self.mostDirectoryBytes { break }
            guard let raw = try? handle.read(upToCount: directoryEntrySize),
                raw.count == directoryEntrySize
            else { break }
            // A free slot, as mkgmap's reader skips it, where the directory's end is known.
            guard raw.first == 1 else {
                if directoryEnd != nil { continue }
                break
            }

            let entry = [UInt8](raw)
            // `CodePage.latin1`, not Foundation's Latin-1, which off Apple's platforms returns
            // nil for a large buffer (a 40 kB page broke every elevation download).
            let name = CodePage.latin1(entry[1..<9]).trimmingCharacters(in: .whitespaces)
            let ext = CodePage.latin1(entry[9..<12]).trimmingCharacters(in: .whitespaces)
            let size = Int(
                UInt32(entry[0x0C]) | UInt32(entry[0x0D]) << 8
                    | UInt32(entry[0x0E]) << 16 | UInt32(entry[0x0F]) << 24
            )
            let blocks = blockList(in: entry)
            let key = "\(name).\(ext)"

            if found[key] != nil {
                found[key]?.blocks.append(contentsOf: blocks)
            } else {
                found[key] = SubFile(
                    name: name,
                    ext: ext,
                    size: size,
                    blocks: blocks,
                    blockSize: blockSize
                )
                order.append(key)
            }
        }

        return (order.compactMap { found[$0] }.filter { !$0.name.isEmpty }, directoryEnd)
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
        // corrupt container can set to 4 GB.
        let plausible = file.blocks.count * file.blockSize
        out.reserveCapacity(min(remaining, max(0, plausible)))

        while remaining > 0 {
            let blockIndex = cursor / file.blockSize
            let within = cursor % file.blockSize
            guard blockIndex < file.blocks.count else { break }
            let take = min(file.blockSize - within, remaining)
            let position = file.blocks[blockIndex] * file.blockSize + within
            guard (try? handle.seek(toOffset: UInt64(position))) != nil,
                let chunk = try? handle.read(upToCount: take), !chunk.isEmpty
            else { break }
            out.append(chunk)
            cursor += chunk.count
            remaining -= chunk.count
        }
        // All that was asked, or nothing: a part of a subfile read as the whole of it is a
        // map cut short taken for a smaller one.
        return out.isEmpty || remaining > 0 ? nil : out
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
            head.count >= 0x33
        else { return nil }
        let bytes = [UInt8](head)
        guard bytes.count > 12,
            Array(bytes[2..<12]) == Array("GARMIN TYP".utf8)
        else { return nil }
        let family = Int(bytes[0x2F]) | Int(bytes[0x30]) << 8
        let product = Int(bytes[0x31]) | Int(bytes[0x32]) << 8
        guard family > 0 else { return nil }
        return (family, max(1, product), sub.size)
    }

    /// Extracts the embedded TYP to `destination`. Returns false where there is none.
    @discardableResult
    static func extractTYP(from url: URL, to destination: URL) -> Bool {
        guard let sub = typSubFile(in: url),
            let data = read(sub, from: url), data.count > 0x33
        else { return false }
        Paths.ensure(destination.deletingLastPathComponent())
        return (try? FileTools.write(data, to: destination)) != nil
    }
}
