#if !os(Windows)
import Foundation

@testable import kmap

#if canImport(Glibc)
import Glibc
#endif

/// A small HTTP/1.1 server on 127.0.0.1 for the downloader's tests. Each connection gets
/// 1 answer from `respond` and is closed; an answer may stop part-way through its body,
/// as a dropped connection does.
final class LoopbackServer: Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Reply {
        var status: Int
        var headers: [(String, String)] = []
        var body = Data()
        /// Body bytes sent before the connection is dropped; nil sends them all.
        var cut: Int?
    }

    let port: UInt16
    private let listener: Int32

    init(respond: @escaping @Sendable (Request) -> Reply) throws {
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        let accepting = Thread { [respond] in
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 { return }
                DispatchQueue.global().async { Self.serve(connection, respond) }
            }
        }
        accepting.start()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    private static func serve(_ connection: Int32, _ respond: (Request) -> Reply) {
        defer { close(connection) }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count <= 0 { return }
            received.append(contentsOf: buffer[0..<count])
        }
        let lines = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(first[0]), path: String(first[1]), headers: headers)
        let reply = respond(request)
        var head = "HTTP/1.1 \(reply.status) Reply\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if request.method != "HEAD" { out.append(reply.body.prefix(reply.cut ?? reply.body.count)) }
        out.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                #if canImport(Glibc)
                let count = send(connection, bytes.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let count = send(connection, bytes.baseAddress! + sent, bytes.count - sent, 0)
                #endif
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
#endif
