import Foundation

/// Adds kmap's own sections to whatever TYP a build is using: the repair pass emits 2
/// type codes no other style draws. The sections travel with the build: the original file
/// is never written to, a TYP already defining one of these types keeps its own, and
/// everything else comes through verbatim with the sections appended.
enum TypAugment {
    /// Where a copy goes when the caller names nowhere. A build names its own scratch
    /// directory instead, so the copy - which carries the theme applied to it - is removed
    /// with the rest of that build's work files.
    static var directory: URL {
        Paths.styles.appendingPathComponent("build-typ", isDirectory: true)
    }

    /// Returns the TYP a build should use, adding kmap's sections where they are missing.
    /// Never fails: a style that cannot be augmented still builds, with its repairs drawn
    /// by the device, and the reason is reported in `Result.refusal`.
    static func prepare(
        _ typURL: URL?,
        theme: TypEdit.Theme = .all,
        into destination: URL? = nil,
        rules: URL? = nil,
        liftingOpenGround: Bool = false
    ) -> Result? {
        guard let typURL, FileTools.exists(typURL) else { return nil }

        // A compiled TYP cannot have sections appended to it as text; importing it
        // decompiles it.
        guard typURL.pathExtension.lowercased() == "txt" else {
            return compiledCopy(typURL, theme: theme, into: destination)
        }
        guard let data = try? Data(contentsOf: typURL) else {
            return Result(url: typURL, added: [], refusal: nil)
        }
        var copy = Copy(data)
        if theme != .all { copy.keep(theme) }
        let source = TypSource.parse(copy.text)
        copy.mark(in: source, rules: rules)
        copy.layWoodsOverTints()
        if liftingOpenGround { copy.liftOpenGround(in: source, rules: rules) }

        // Handed through as it is only where mkgmap reads it as kmap does. A build always
        // gets a copy.
        guard !copy.marks.wanted.isEmpty || copy.text != copy.original || !copy.readsAlike || destination != nil
        else {
            return Result(url: typURL, added: [], theme: copy.themeNote, refusal: nil, moved: [:])
        }
        copy.append(
            additions(
                wanted: copy.marks.wanted,
                moved: copy.marks.moved,
                copies: copy.lifted.copies,
                byteForByte: copy.byteForByte
            ),
            from: typURL,
            theme: theme
        )
        return copy.written(from: typURL, into: destination ?? directory)
    }
}
