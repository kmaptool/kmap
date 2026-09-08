import Foundation

/// Makes an error that already describes itself say the same thing when it is *asked* to.
///
/// Swift has two ways of getting words out of an error and they do not talk to each other.
/// `CustomStringConvertible.description` is what string interpolation uses;
/// `Error.localizedDescription` is what Foundation uses, and it consults `description` not
/// at all — it looks for a `LocalizedError`, and where there is none it returns a sentence
/// assembled from the type's name and the case's ordinal:
///
///     The operation could not be completed. (kmap.ViewfinderDEM.Trouble error 0.)
///
/// That is what a failed build printed for a whole class of errors here, each of which had
/// a perfectly good sentence written for it a few lines above. The build pipeline and the
/// command line both report through `localizedDescription`, so the sentence was never
/// reached.
///
/// One default, rather than the same three lines in a dozen files: an error type that
/// already has a `description` gains `errorDescription` by adding `LocalizedError` to its
/// conformance list and nothing else. A type that wants the two to differ still may — an
/// explicit `errorDescription` wins over this.
extension LocalizedError where Self: CustomStringConvertible {
    var errorDescription: String? { description }
}
