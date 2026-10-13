import Foundation

extension StyleRecovery {
    /// What resolving one code decided, kept for the silencing pass: whether any chosen
    /// meaning already emits the code - the 2 vocabularies agreeing on the number -
    /// and the words for the comment when they do not.
    struct CodeVerdict {
        let agrees: Bool
        let meaning: String
    }
}
