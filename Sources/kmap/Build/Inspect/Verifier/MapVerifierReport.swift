import Foundation

extension MapVerifier {
    /// Every check on 1 map.
    struct Report {
        let url: URL
        var findings: [Finding] = []
        var failed: Bool { findings.contains { $0.level == .fail } }
        var warned: Bool { findings.contains { $0.level == .warn } }
    }
}
