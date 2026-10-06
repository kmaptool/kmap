import Foundation

extension TypLibrary {
    /// What an import produced.
    struct Imported {
        /// The library entry - the file the editor will be pointed at.
        let url: URL
        /// True when the TYP was compiled and has been written back out as source.
        let decompiled: Bool
        /// How many elements were read, and how many of those the decoder refused.
        let elements: Int
        let refused: Int
        /// Where the untouched original was kept, for a compiled import.
        let original: URL?
        /// The TYP's own bytes, boiled down to a number, written into the import log.
        let fingerprint: UInt64
    }
}
