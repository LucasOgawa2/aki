#if !canImport(Network)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// HTTP server bound to 127.0.0.1 only, on plain sockets where there's no Network
/// framework (Linux). Same contract as the macOS one: one request per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let requestedPort: UInt16
    private let maxBody: Int
    private let handler: Handler
    // Guards `listening`: the accept thread and `stop` both touch it.
    private let lock = NSLock()
    private var listening: Int32 = -1

    /// `port` 0 picks a free port (used by the checks).
    public init(port: UInt16, maxBody: Int = 25 * 1024 * 1024, handler: @escaping Handler) {
        requestedPort = port
        self.maxBody = maxBody
        self.handler = handler
    }

    /// Starts listening and returns the port. Throws if the port is taken.
    public func start() async throws -> UInt16 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw Self.error() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let error = Self.error()
            close(fd)
            throw error
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let error = Self.error()
            close(fd)
            throw error
        }
        lock.withLock { listening = fd }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "aki.http"
        thread.start()
        return UInt16(bigEndian: address.sin_port)
    }

    public func stop() {
        lock.withLock {
            guard listening >= 0 else { return }
            let fd = listening
            listening = -1
            // The loop owns close. Keep shutdown under its closing lock so a reused
            // descriptor can never be shut down by an earlier stop call.
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            lock.withLock {
                if listening == fd { listening = -1 }
                close(fd)
            }
        }
        while true {
            guard lock.withLock({ listening == fd }) else { return }
            // This toolchain's Glibc module does not expose accept4.
            let connection = accept(fd, nil, nil)
            if connection >= 0 {
                guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                      lock.withLock({ listening == fd }) else {
                    close(connection)
                    continue
                }
                DispatchQueue.global().async { [self] in serve(connection) }
                continue
            }
            let failure = errno
            guard lock.withLock({ listening == fd }) else { return }
            if failure == EINTR || failure == ECONNABORTED { continue }
            if failure == EMFILE || failure == ENFILE || failure == ENOBUFS || failure == ENOMEM {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            return
        }
    }

    private func serve(_ connection: Int32) {
        // A client that stops sending mid-request doesn't hold its thread for good.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            close(connection)
            return
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            if count > 0 { buffer.append(contentsOf: chunk[0..<count]) }
            switch HTTPRequest.parse(buffer, maxBody: maxBody) {
            case .complete(let request):
                let handler = handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
                return
            case .incomplete where count > 0:
                continue
            case .incomplete:
                close(connection)
                return
            case .invalid(let status, let reason):
                Self.send(.error(status, reason), on: connection)
                return
            }
        }
    }

    private static func send(_ response: HTTPResponse, on connection: Int32) {
        let data = response.serialized()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                // MSG_NOSIGNAL: a client gone away is an error here, not a SIGPIPE.
                let sent = Glibc.send(connection, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { break }
                offset += sent
            }
        }
        close(connection)
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
