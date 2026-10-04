import Foundation

/// An error in the words written for it, for a person or a stream to read. A system error
/// interpolated as it is prints its whole record, a memory address included.
enum ErrorWords {
    /// The domains of the errors Foundation and the system raise.
    private static let systemDomains: Set<String> = [
        NSCocoaErrorDomain, NSPOSIXErrorDomain, "NSURLErrorDomain", "NSOSStatusErrorDomain"
    ]

    static func of(_ error: Error) -> String {
        if let words = (error as? LocalizedError)?.errorDescription { return words }
        // Their own description names the key and the path that failed, which the bridged
        // words of a Mac leave out.
        if error is DecodingError || error is EncodingError { return "\(error)" }
        // The system's errors are asked for their words, whatever shape they arrive in:
        // CocoaError, URLError and POSIXError values, or NSError objects. A type of kmap's
        // own prints as its case.
        let ns = error as NSError
        guard type(of: error) is NSError.Type || systemDomains.contains(ns.domain) else { return "\(error)" }
        let words = error.localizedDescription
        // The file or address it was about, which Linux and Windows leave out of the words,
        // and every system leaves out for an address. A file is named by its path.
        func named(_ url: URL?) -> String? { url.map { $0.isFileURL ? $0.path : $0.absoluteString } }
        let subject =
            ns.userInfo[NSFilePathErrorKey] as? String
            ?? named(ns.userInfo[NSURLErrorKey] as? URL)
            ?? ns.userInfo["NSErrorFailingURLStringKey"] as? String
            ?? named(ns.userInfo["NSErrorFailingURLKey"] as? URL)
        guard let subject, !subject.isEmpty, !words.contains(subject) else { return words }
        return "\(words) (\(subject))"
    }
}
