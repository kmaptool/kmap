import Foundation

extension TypAugment {
    /// Paints line numbers clear in the build's TYP copy: lines a palette written for
    /// kmap's numbers leaves unpainted, drawn by rules that could not be silenced.
    /// Unpainted, the receiver would draw them its own way, which is no look of the
    /// style. An area needs none of this: missing from the draw order, it is not drawn.
    /// - Returns: how many numbers were painted clear, nil where the copy could not be
    ///   read or written.
    static func paintClear(lines codes: Set<Int>, in typ: URL) -> Int? {
        guard let data = try? Data(contentsOf: typ) else { return nil }
        let (text, byteForByte) = TypSource.decoding([UInt8](data))
        let source = TypSource.parse(text)
        let sections = codes.sorted().filter { source.section(.line, $0) == nil }
            .map { nothing(code: $0, labels: []).joined(separator: "\n") }
        guard !sections.isEmpty else { return 0 }
        var out = text
        if !out.hasSuffix("\n") { out += "\n" }
        out += "\n; Painted clear by kmap: this style draws nothing here.\n\n"
        out += sections.joined(separator: "\n\n") + "\n"
        let bytes = TypSource.bytesToWrite(out, declaring: true, byteForByte: byteForByte)
        guard (try? FileTools.write(bytes, to: typ)) != nil else { return nil }
        return sections.count
    }
}
