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
