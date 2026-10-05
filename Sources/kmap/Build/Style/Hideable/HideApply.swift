import Foundation

/// The hide pass: features the user turned off lose their type, and keep their routing.
extension StyleCatalog {
    /// Drops the chosen features from the rule set.
    ///
    /// Each substitution keeps the rule's actions and removes only its `[0x... ]` type, so
    /// routing still happens. Nothing is removed from the source data.
    func hideFeatures(_ hidden: Set<String>, in directory: URL, log: Log) throws {
        guard !hidden.isEmpty else { return }
        var applied: [String] = []
        var missed: [String] = []

        for id in hidden.sorted() {
            guard let feature = HideableFeature.feature(id: id) else { continue }
            var ok = false
            for substitution in feature.substitutions {
                let url = directory.appendingPathComponent(substitution.file)
                guard var text = try? String(contentsOf: url, encoding: .utf8),
                    text.contains(substitution.old)
                else { continue }
                text = text.replacingOccurrences(of: substitution.old, with: substitution.new)
                try FileTools.write(text, to: url)
                ok = true
            }
            if ok { applied.append(feature.name) } else { missed.append(feature.name) }
        }

        if !applied.isEmpty { log.append("hidden: \(applied.joined(separator: ", "))") }
        for name in missed {
            log.warn("could not hide \(name) — the rule has changed in this mkgmap")
        }
    }
}
