import Foundation

extension TypAugment.Copy {
    /// Writes the copy beside the build and says what it gained; the original is never
    /// written to.
    func written(from typURL: URL, into folder: URL) -> TypAugment.Result {
        let written = folder.appendingPathComponent(typURL.lastPathComponent)

        // The original is never written to. The copy keeps the original's name, so a style
        // living in the destination folder would otherwise be overwritten by its own copy.
        guard written.standardizedFileURL != typURL.standardizedFileURL else {
            return TypAugment.Result(
                url: typURL,
                added: [],
                theme: themeNote,
                refusal: "\(typURL.lastPathComponent) sits where the build writes"
                    + " its own copy, so it is used as it is — kmap will not"
                    + " write over a TYP you own"
            )
        }

        Paths.ensure(folder)
        // Stale copies from the shared folder: the shared name would let a theme chosen
        // once outlive the build that chose it. Removed only when nothing being read lives
        // there.
        if folder != TypAugment.directory,
            !typURL.standardizedFileURL.path.hasPrefix(TypAugment.directory.standardizedFileURL.path)
        {
            FileTools.removeIfPresent(TypAugment.directory)
        }
        // Written as UTF-8, and said to be: without the line mkgmap would read it in the
        // CodePage it names, and the marks' Cyrillic would come out garbled. A page kmap
        // cannot read goes back in its own bytes.
        let bytes = TypSource.bytesToWrite(text, declaring: true, byteForByte: byteForByte)
        do {
            try FileTools.write(bytes, to: written)
        } catch {
            return TypAugment.Result(
                url: typURL,
                added: [],
                theme: nil,
                refusal: "the build's copy of \(typURL.lastPathComponent) could not be written"
                    + " (\(ErrorWords.of(error))), so it is used as it is, without marks or theme"
            )
        }

        return TypAugment.Result(
            url: written,
            added: (addedAny ? marks.wanted : []).map { mark in
                let moved = marks.moved[mark.kind]?.first { $0.value == mark.code }
                return "\(TypeMeaning.hex(mark.code)) — \(mark.what)"
                    + (moved.map {
                        " (moved off \(TypeMeaning.hex($0.key)),"
                            + " which this style already draws)"
                    } ?? "")
            },
            theme: themeNote,
            refusal: nil,
            moved: marks.moved,
            woodsLaidOver: woodsLaidOver,
            shapeLift: lifted.shapeLift
        )
    }
}
