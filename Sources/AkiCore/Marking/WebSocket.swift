#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A small WebSocket client (RFC 6455), only what talking to Chrome's DevTools on
/// 127.0.0.1 needs: the opening handshake, text messages (masked, as a client must),
/// fragments, ping/pong and close. Foundation's `URLSessionWebSocketTask` builds on Linux
/// but doesn't work there (Ubuntu 24.04's libcurl has no `ws`). The bytes are this
/// file's; the socket is the caller's `ByteStream`.
extension LinuxMarking {
    public enum WebSocket {
        public enum Opcode: UInt8, Sendable {
            case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
        }

        public enum Failure: Error, Equatable, Sendable {
            case refused(String), tooLarge, binary, unknownOpcode(UInt8), badContinuation, notUTF8, masked, closed, timedOut, io(String)
        }

        /// What the server sent, as the client sees it.
        public enum Incoming: Equatable, Sendable {
            case text(String), ping([UInt8]), pong, close
        }

        /// The longest message taken (Chrome's answers are a few KB; an element's HTML is cut at 300).
        public static let maxMessage = 4 << 20

        static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        /// `Sec-WebSocket-Accept` for this key: base64(SHA-1(key + GUID)).
        public static func acceptValue(forKey key: String) -> String {
            Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
        }

        /// The opening request. No `Origin`: Chrome refuses a WebSocket with one it wasn't
        /// told to allow (`--remote-allow-origins`), and a client that isn't a page has none.
        public static func handshake(host: String, port: Int, path: String, key: String) -> [UInt8] {
            Array(("GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
        }

        public enum HandshakeOutcome: Equatable, Sendable {
            case incomplete
            /// The bytes after the headers are already the first frames.
            case accepted(leftover: [UInt8])
            case refused(String)
        }

        public static func readHandshake(_ bytes: [UInt8], key: String) -> HandshakeOutcome {
            guard let head = MiniHTTP.head(of: bytes) else {
                return bytes.count > MiniHTTP.maxHead ? .refused("headers too long") : .incomplete
            }
            guard head.status == 101 else { return .refused(head.statusLine) }
            guard head.headers["upgrade"]?.lowercased() == "websocket" else { return .refused("no Upgrade: websocket") }
            guard head.headers["sec-websocket-accept"] == acceptValue(forKey: key) else { return .refused("wrong Sec-WebSocket-Accept") }
            return .accepted(leftover: Array(bytes[head.end...]))
        }

        /// One whole frame (FIN set), masked with `mask` (4 bytes).
        public static func frame(_ opcode: Opcode, payload: [UInt8], mask: [UInt8]) -> [UInt8] {
            var bytes: [UInt8] = [0x80 | opcode.rawValue]
            let count = payload.count
            if count < 126 {
                bytes.append(0x80 | UInt8(count))
            } else if count <= 0xFFFF {
                bytes += [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
            } else {
                bytes.append(0x80 | 127)
                bytes += (0..<8).reversed().map { UInt8((UInt64(count) >> (8 * UInt64($0))) & 0xFF) }
            }
            bytes += mask
            bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            return bytes
        }

        /// Turns the server's bytes into messages, a piece at a time.
        public struct Reader: Sendable {
            private var buffer: [UInt8] = []
            private var start = 0
            /// A text in fragments, until its FIN.
            private var partial: [UInt8]?
            public init() {}

            public mutating func feed(_ bytes: [UInt8]) {
                if start > 0 {
                    buffer.removeFirst(start)
                    start = 0
                }
                buffer += bytes
            }

            /// The next whole message, nil when more bytes are needed. Control frames
            /// (ping, pong, close) may come between a message's fragments.
            public mutating func next() throws -> Incoming? {
                while true {
                    let available = buffer.count - start
                    guard available >= 2 else { return nil }
                    let first = buffer[start], second = buffer[start + 1]
                    guard second & 0x80 == 0 else { throw Failure.masked }
                    var length = Int(second & 0x7F), header = 2
                    if length == 126 {
                        guard available >= 4 else { return nil }
                        length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                        header = 4
                    } else if length == 127 {
                        guard available >= 10 else { return nil }
                        var big: UInt64 = 0
                        for i in 2..<10 { big = big << 8 | UInt64(buffer[start + i]) }
                        guard big <= UInt64(maxMessage) else { throw Failure.tooLarge }
                        length = Int(big)
                        header = 10
                    }
                    guard length <= maxMessage, (partial?.count ?? 0) + length <= maxMessage else { throw Failure.tooLarge }
                    let fin = first & 0x80 != 0
                    guard let opcode = Opcode(rawValue: first & 0x0F) else { throw Failure.unknownOpcode(first & 0x0F) }
                    // Refused before its bytes come: a 4 MB answer never sits in memory twice.
                    switch opcode {
                    case .binary: throw Failure.binary
                    case .continuation: if partial == nil { throw Failure.badContinuation }
                    case .text: if partial != nil { throw Failure.badContinuation }
                    case .close, .ping, .pong: break
                    }
                    guard available >= header + length else { return nil }
                    let payload = Array(buffer[(start + header)..<(start + header + length)])
                    start += header + length
                    switch opcode {
                    case .ping: return .ping(payload)
                    case .pong: return .pong
                    case .close: return .close
                    case .binary: throw Failure.binary
                    case .text, .continuation:
                        let whole = (partial ?? []) + payload
                        guard fin else {
                            partial = whole
                            continue
                        }
                        partial = nil
                        // Foundation's decoder refuses bad UTF-8 (`String(validating:)` needs macOS 15).
                        guard let text = String(bytes: whole, encoding: .utf8) else { throw Failure.notUTF8 }
                        return .text(text)
                    }
                }
            }
        }
    }

    /// A GET over a fresh connection (`Connection: close`): Chrome's `/json/version`.
    public enum MiniHTTP {
        public static func get(host: String, port: Int, path: String) -> [UInt8] {
            Array("GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8)
        }

        /// The most of a response's status line and headers taken.
        static let maxHead = 16 << 10

        struct Head {
            var statusLine: String
            var status: Int
            /// Names lowercased.
            var headers: [String: String]
            /// Where the body starts.
            var end: Int
        }

        /// The status line and headers, once they're all there (nil before, or not HTTP).
        static func head(of bytes: [UInt8]) -> Head? {
            let crlf: [UInt8] = [13, 10, 13, 10]
            guard bytes.count >= 4,
                  let end = (0...(bytes.count - 4)).first(where: { bytes[$0..<($0 + 4)].elementsEqual(crlf) }) else { return nil }
            let lines = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return nil }
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
                return Head(statusLine: statusLine, status: -1, headers: [:], end: end + 4)
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return Head(statusLine: statusLine, status: status, headers: headers, end: end + 4)
        }

        public enum Outcome: Equatable, Sendable {
            case incomplete
            case response(status: Int, body: [UInt8])
            case malformed
        }

        /// The longest answer taken.
        public static let maxResponse = 4 << 20

        /// `closed`: the server closed the connection (a body without a length ends there).
        public static func parse(_ bytes: [UInt8], closed: Bool) -> Outcome {
            guard let head = head(of: bytes) else {
                return closed || bytes.count > maxHead ? .malformed : .incomplete
            }
            guard head.status >= 0 else { return .malformed }
            let body = bytes.count - head.end
            if let field = head.headers["content-length"] {
                guard let length = Int(field), length >= 0, length <= maxResponse else { return .malformed }
                if body >= length { return .response(status: head.status, body: Array(bytes[head.end..<(head.end + length)])) }
                return closed ? .malformed : .incomplete
            }
            guard body <= maxResponse else { return .malformed }
            return closed ? .response(status: head.status, body: Array(bytes[head.end...])) : .incomplete
        }
    }
}

/// The socket under a `WebSocketConnection` or a `MiniHTTP.fetch`: the overlay's is
/// POSIX, the checks' a script. Every call has the one deadline of the whole read.
public protocol ByteStream: AnyObject {
    /// All of `bytes`, or throws (`WebSocket.Failure.timedOut` past the deadline, `.io` else).
    func write(_ bytes: [UInt8], until deadline: ContinuousClock.Instant) throws
    /// Some bytes; none when the other side closed.
    func read(until deadline: ContinuousClock.Instant) throws -> [UInt8]
    func close()
}

extension LinuxMarking {
    /// A text-message WebSocket over a stream, open from `init` (the handshake done).
    public final class WebSocketConnection {
        private let stream: ByteStream
        private let mask: () -> [UInt8]
        private var reader = WebSocket.Reader()

        /// `key`: 16 random bytes in base64; `mask`: 4 new random bytes per frame.
        public init(stream: ByteStream, host: String, port: Int, path: String, until deadline: ContinuousClock.Instant,
                    key: String = WebSocketConnection.randomKey(), mask: @escaping () -> [UInt8] = WebSocketConnection.randomMask) throws {
            self.stream = stream
            self.mask = mask
            try stream.write(WebSocket.handshake(host: host, port: port, path: path, key: key), until: deadline)
            var received: [UInt8] = []
            while true {
                let bytes = try stream.read(until: deadline)
                guard !bytes.isEmpty else { throw WebSocket.Failure.closed }
                received += bytes
                switch WebSocket.readHandshake(received, key: key) {
                case .incomplete: continue
                case let .refused(why): throw WebSocket.Failure.refused(why)
                case let .accepted(leftover):
                    reader.feed(leftover)
                    return
                }
            }
        }

        public static func randomKey() -> String { Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
        public static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }

        public func send(_ text: String, until deadline: ContinuousClock.Instant) throws {
            try stream.write(WebSocket.frame(.text, payload: Array(text.utf8), mask: mask()), until: deadline)
        }

        /// The next text message; pings are answered on the way, a close ends it (`.closed`).
        public func receive(until deadline: ContinuousClock.Instant) throws -> String {
            while true {
                while let message = try reader.next() {
                    switch message {
                    case let .text(text): return text
                    case let .ping(payload): try stream.write(WebSocket.frame(.pong, payload: payload, mask: mask()), until: deadline)
                    case .pong: continue
                    case .close: throw WebSocket.Failure.closed
                    }
                }
                let bytes = try stream.read(until: deadline)
                guard !bytes.isEmpty else { throw WebSocket.Failure.closed }
                reader.feed(bytes)
            }
        }

        public func close() { stream.close() }
    }
}

extension LinuxMarking.MiniHTTP {
    /// GETs `path` over `stream` (closed after), up to the deadline.
    public static func fetch(_ path: String, host: String, port: Int, over stream: ByteStream, until deadline: ContinuousClock.Instant) throws
        -> (status: Int, body: [UInt8]) {
        defer { stream.close() }
        try stream.write(get(host: host, port: port, path: path), until: deadline)
        var received: [UInt8] = []
        while true {
            let bytes = try stream.read(until: deadline)
            received += bytes
            switch parse(received, closed: bytes.isEmpty) {
            case let .response(status, body): return (status, body)
            case .malformed: throw LinuxMarking.WebSocket.Failure.io("malformed HTTP response")
            case .incomplete: continue
            }
        }
    }
}
