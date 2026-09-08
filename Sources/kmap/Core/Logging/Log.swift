import Foundation

/// Where a run says what it is doing.
///
/// One log per run, handed down to whatever does the work. It numbers each event, drops
/// the ones below its floor, and passes the rest to every attached sink: the ring the
/// interface draws, the file the run leaves behind, the JSON stream a program reads.
/// Nothing that produces a message needs to know which of those exist.
final class Log {
    /// A sink and the lowest severity it wants. The interface asks for less than the file
    /// the run leaves behind, which is why the floor belongs here and not on the log.
    private struct Outlet {
        let sink: LogSink
        var floor: LogSeverity
    }

    private let lock = NSLock()
    private var outlets: [Outlet]
    private var lowest: LogSeverity
    private var sequence = 0
    private let ring: LogRing

    /// - Parameters:
    ///   - limit: how many events the ring keeps for the interface.
    ///   - mirrorTo: a file to write to. It takes everything, including detail the
    ///     interface is not showing, since it is what a finished run is read back from.
    ///   - showing: the lowest severity the interface sees.
    init(limit: Int = 4000, mirrorTo url: URL? = nil, showing: LogSeverity = .info) {
        ring = LogRing(limit: limit)
        outlets = [Outlet(sink: ring, floor: showing)]
        if let url, let file = LogFile(at: url) {
            outlets.append(Outlet(sink: file, floor: .debug))
        }
        lowest = outlets.map(\.floor).min() ?? showing
    }

    /// The lowest severity the interface shows. Lowering it does not bring back what was
    /// already said: an event below the floor of every outlet is never made.
    var showing: LogSeverity {
        get { lock.lock(); defer { lock.unlock() }; return outlets[0].floor }
        set {
            lock.lock()
            outlets[0].floor = newValue
            lowest = outlets.map(\.floor).min() ?? newValue
            lock.unlock()
        }
    }

    /// - Parameter showing: the lowest severity this sink wants.
    func attach(_ sink: LogSink, showing floor: LogSeverity = .debug) {
        lock.lock()
        outlets.append(Outlet(sink: sink, floor: floor))
        lowest = outlets.map(\.floor).min() ?? floor
        lock.unlock()
    }

    /// Numbers the event and hands it to every sink that wants it. Control sequences are
    /// stripped and the text is trimmed; an event whose text comes out empty is dropped,
    /// since a blank line from another program means nothing to anyone.
    ///
    /// The number counts what was made, not what each sink saw, so one reader's gap is a
    /// line another reader was shown and it was not.
    func send(_ event: LogEvent) {
        var event = event
        event.text = stripControlSequences(event.text)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !event.text.isEmpty else { return }

        lock.lock()
        guard event.severity >= lowest else { lock.unlock(); return }
        sequence += 1
        event.seq = sequence
        let targets = outlets
        lock.unlock()

        for outlet in targets where event.severity >= outlet.floor {
            outlet.sink.receive(event)
        }
    }

    // MARK: What the work says

    /// An ordinary line: what is happening, in the words the user thinks in.
    func append(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .info, kind: .plain, stage: stage,
                      fields: fields))
    }

    /// A piece of work starting.
    func step(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .info, kind: .step, stage: stage,
                      fields: fields))
    }

    /// A piece of work that finished as it should.
    func ok(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .info, kind: .ok, stage: stage, fields: fields))
    }

    /// The run continues, but something about it is not what was asked for.
    func warn(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .warn, kind: .plain, stage: stage,
                      fields: fields))
    }

    /// The run cannot do what it was asked to do.
    func error(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .error, kind: .plain, stage: stage,
                      fields: fields))
    }

    /// Detail for working out why a run behaved as it did. Off unless asked for.
    func debug(_ text: String, stage: String? = nil, fields: [String: JSONValue] = [:]) {
        send(LogEvent(text: text, severity: .debug, kind: .plain, stage: stage,
                      fields: fields))
    }

    /// A line as another program wrote it. Debug, because a person reading a build wants
    /// kmap's account of it and not mkgmap's.
    func output(_ text: String, stage: String? = nil) {
        send(LogEvent(text: text, severity: .debug, kind: .output, stage: stage))
    }

    // MARK: What the interface reads

    func snapshot() -> [LogEvent] { ring.snapshot() }

    var count: Int { ring.count }
}
