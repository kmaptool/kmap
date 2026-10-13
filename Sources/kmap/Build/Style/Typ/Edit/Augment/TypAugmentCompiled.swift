import Foundation

extension TypAugment {
    /// A compiled TYP handed over as it is, with the reason nothing could be added to it.
    static func compiledCopy(_ typURL: URL, theme: TypEdit.Theme, into destination: URL?) -> Result {
        // The day/night pass reads the same text the repair marks are added to, so a
        // compiled TYP defeats both.
        let what =
            theme == .all
            ? "kmap's repair marks cannot be added to it"
            : "kmap can neither drop its night colours nor add "
                + "the repair marks"
        // Handed over as a copy beside the build: mkgmap writes its own copy, with the
        // map's family id, next to the file it is given, and in the user's folder that
        // copy would be taken for a style of its own.
        let folder = destination ?? directory
        let copy = folder.appendingPathComponent(typURL.lastPathComponent)
        var refusal =
            "\(typURL.lastPathComponent) is a compiled TYP, so \(what)"
            + " — import it again to decompile it, and it will work"
        // Already where a copy would go: it is a copy.
        guard !copy.sameFile(as: typURL) else {
            return Result(url: typURL, added: [], theme: nil, refusal: refusal)
        }
        Paths.ensure(folder)
        FileTools.removeIfPresent(copy)
        do {
            try FileTools.copy(typURL, to: copy)
        } catch {
            // Built without it rather than with the user's own file: mkgmap would write
            // its own copy into the user's folder. A part-written copy would be passed on.
            FileTools.removeIfPresent(copy)
            refusal +=
                "; it could not be copied for this build (\(ErrorWords.of(error))), so the map is built without it"
            return Result(url: copy, added: [], theme: nil, refusal: refusal)
        }
        return Result(url: copy, added: [], theme: nil, refusal: refusal)
    }
}
