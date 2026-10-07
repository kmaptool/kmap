import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a URLSession of kmap's own goes when it is done with.
///
/// Where URLSession runs on libcurl (Linux, Windows), a freed session's curl handle calls
/// back into the session from its deinit; with the libcurl of Ubuntu 26.04 that corrupts
/// the heap and the process dies. So there a retired session is invalidated and kept for
/// the life of the process: a few small objects per download. On Apple systems it is
/// only invalidated.
enum RetiredSessions {
    #if canImport(FoundationNetworking)
    private static let kept = Locked<[URLSession]>([])
    #endif

    /// Cancels what `session` still runs and lets go of its delegate.
    static func cancel(_ session: URLSession) {
        session.invalidateAndCancel()
        keep(session)
    }

    /// Lets what `session` still runs finish, then lets go of its delegate.
    static func finish(_ session: URLSession) {
        session.finishTasksAndInvalidate()
        keep(session)
    }

    /// Sessions kept so far; 0 on Apple systems.
    static var count: Int {
        #if canImport(FoundationNetworking)
        kept.withLock { $0.count }
        #else
        0
        #endif
    }

    private static func keep(_ session: URLSession) {
        #if canImport(FoundationNetworking)
        kept.withLock { sessions in
            if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
        }
        #endif
    }
}
