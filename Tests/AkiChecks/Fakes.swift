import AkiCore
import Foundation

/// A socket that plays a script: each read gives the next chunk (none left: closed),
/// or throws what the script says; what's written is kept.
final class ScriptedStream: ByteStream {
    enum Step { case bytes([UInt8]), fail(LinuxMarking.WebSocket.Failure) }
    var steps: [Step]
    var written: [[UInt8]] = []
    var closed = false
    init(_ steps: [Step]) { self.steps = steps }
    func write(_ bytes: [UInt8], until deadline: ContinuousClock.Instant) throws { written.append(bytes) }
    func read(until deadline: ContinuousClock.Instant) throws -> [UInt8] {
        guard !steps.isEmpty else { return [] }
        switch steps.removeFirst() {
        case let .bytes(b): return b
        case let .fail(f): throw f
        }
    }
    func close() { closed = true }
}

/// A browser that answers each call as `answer` says (any number of messages per call:
/// events, late or out-of-order answers); with nothing to read, it times out.
final class ScriptedChannel: MessageChannel {
    var sent: [[String: JSONValue]] = []
    var inbox: [String] = []
    var answer: (_ id: Int, _ method: String, _ params: [String: JSONValue], _ session: String?) -> [String]
    init(_ answer: @escaping (_ id: Int, _ method: String, _ params: [String: JSONValue], _ session: String?) -> [String]) { self.answer = answer }
    func send(_ text: String, until deadline: ContinuousClock.Instant) throws {
        let message = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))) ?? [:]
        sent.append(message)
        inbox += answer(Int(message["id"]?.double ?? -1), message["method"]?.string ?? "", message["params"]?.object ?? [:], message["sessionId"]?.string)
    }
    func receive(until deadline: ContinuousClock.Instant) throws -> String {
        guard !inbox.isEmpty else { throw LinuxMarking.WebSocket.Failure.timedOut }
        return inbox.removeFirst()
    }
    var closed = false
    func close() { closed = true }
}

func reply(_ id: Int, _ result: String) -> String { #"{"id":\#(id),"result":\#(result)}"# }
