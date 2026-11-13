import AkiCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A TCP connection to 127.0.0.1 (never another host: the endpoint is checked before),
/// non-blocking, each call waiting in `poll()` no longer than the read's one deadline.
final class LoopbackStream: ByteStream {
    private var fd: Int32
    typealias Failure = LinuxMarking.WebSocket.Failure

    init(port: Int, until deadline: ContinuousClock.Instant) throws {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue), 0)
        guard fd >= 0 else { throw Failure.io(Self.why()) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if started != 0 {
            guard errno == EINPROGRESS else {
                let why = Self.why()
                close()
                throw Failure.io(why)
            }
            do { try wait(for: Int16(POLLOUT), until: deadline) } catch {
                close()
                throw error
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else {
                close()
                throw Failure.io(String(cString: strerror(error)))
            }
        }
    }

    func write(_ bytes: [UInt8], until deadline: ContinuousClock.Instant) throws {
        var sent = 0
        while sent < bytes.count {
            guard fd >= 0 else { throw Failure.closed }
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, $0.count - sent, Int32(MSG_NOSIGNAL)) }
            if n > 0 {
                sent += n
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try wait(for: Int16(POLLOUT), until: deadline)
            } else {
                throw Failure.io(Self.why())
            }
        }
    }

    func read(until deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            guard fd >= 0 else { throw Failure.closed }
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { return Array(buffer[..<n]) }
            if n == 0 { return [] }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw Failure.io(Self.why()) }
            try wait(for: Int16(POLLIN), until: deadline)
        }
    }

    func close() {
        guard fd >= 0 else { return }
        Glibc.close(fd)
        fd = -1
    }

    deinit { close() }

    /// Until the socket is ready, or `.timedOut` at the deadline.
    private func wait(for events: Int16, until deadline: ContinuousClock.Instant) throws {
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { throw Failure.timedOut }
            let ms = Int32(min(Double(left.components.seconds) * 1000 + Double(left.components.attoseconds) / 1e15 + 1, 60_000))
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&entry, 1, ms)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw Failure.io(Self.why()) }
        }
    }

    private static func why() -> String { String(cString: strerror(errno)) }
}
