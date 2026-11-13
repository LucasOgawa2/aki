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
    private let requestTimeout: TimeInterval
    private let handlerTimeout: TimeInterval
    private let handler: Handler
    // Guards the listener and the number of active connection threads.
    private let lock = NSLock()
    private var listening: Int32 = -1
    private var activeConnections = 0

    /// `port` 0 picks a free port; `requestTimeout` bounds the full request read from accept.
    /// `handlerTimeout` bounds the wait for a response after a complete request.
    public init(port: UInt16, maxBody: Int = 25 * 1024 * 1024, requestTimeout: TimeInterval = 10, handlerTimeout: TimeInterval = 8, handler: @escaping Handler) {
        requestedPort = port
        self.maxBody = maxBody
        self.requestTimeout = requestTimeout
        self.handlerTimeout = handlerTimeout
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
            // This relies on shutdown waking blocked accept with EINVAL, observed on Linux but not guaranteed by accept(2).
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    public enum AcceptAction: Equatable, Sendable { case retry, pause, stop }

    /// Retry connection errors immediately; pause on firewall denial or resource pressure.
    public static func acceptAction(for failure: Int32) -> AcceptAction {
        switch failure {
        // Linux accept(2): retry pending TCP errors; persistent EPERM needs a pause.
        case EINTR, ECONNABORTED, ENETDOWN, EPROTO, ENOPROTOOPT,
             EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, ENETUNREACH: .retry
        case EPERM, EMFILE, ENFILE, ENOBUFS, ENOMEM: .pause
        default: .stop
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
                let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
                guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                      lock.withLock({
                          guard listening == fd, activeConnections < 64 else { return false }
                          activeConnections += 1
                          return true
                      }) else {
                    close(connection)
                    continue
                }
                let thread = Thread { [self] in
                    defer {
                        close(connection)
                        lock.withLock { activeConnections -= 1 }
                    }
                    serve(connection, deadline: deadline)
                }
                thread.name = "aki.http.connection"
                thread.start()
                continue
            }
            let failure = errno
            guard lock.withLock({ listening == fd }) else { return }
            switch Self.acceptAction(for: failure) {
            case .retry: continue
            case .pause:
                Thread.sleep(forTimeInterval: 0.01)
                continue
            case .stop:
                FileHandle.standardError.write(Data("aki: annotations server stopped accepting: \(String(cString: strerror(failure)))\n".utf8))
                return
            }
        }
    }

    private func serve(_ connection: Int32, deadline: TimeInterval) {
        // Sending keeps a socket timeout; reading has one total deadline from accept.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            let milliseconds = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
            let count = chunk.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            if count > 0 { buffer.append(contentsOf: chunk[0..<count]) }
            switch HTTPRequest.parse(buffer, maxBody: maxBody) {
            case .complete(let request):
                let handler = handler
                let completed = DispatchSemaphore(value: 0)
                let result = ResponseBox()
                Task {
                    result.store(await handler(request))
                    completed.signal()
                }
                guard completed.wait(timeout: .now() + handlerTimeout) == .success else {
                    Self.send(.error(503, "timed out; a write may still be applied"), on: connection)
                    return
                }
                Self.send(result.load(), on: connection)
                return
            case .incomplete where count > 0:
                continue
            case .incomplete:
                return
            case .invalid(let status, let reason):
                Self.send(.error(status, reason), on: connection, drainUpload: true)
                return
            }
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: HTTPResponse?

        func store(_ response: HTTPResponse) { lock.withLock { self.response = response } }
        func load() -> HTTPResponse { lock.withLock { response! } }
    }

    private static func send(_ response: HTTPResponse, on connection: Int32, drainUpload: Bool = false) {
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
        if drainUpload {
            // FIN lets the client finish reading; drain unread upload bytes to avoid RST.
            shutdown(connection, Int32(SHUT_WR))
            drain(connection)
        }
    }

    private static func drain(_ connection: Int32) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return }
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            // Keep draining nonblocking after poll.
            let count = recv(connection, &chunk, chunk.count, Int32(MSG_DONTWAIT))
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0 else { return }
        }
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
