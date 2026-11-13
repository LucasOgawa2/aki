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

/// A browser with these pages, each window's bounds, visibility and title; the
/// extraction answers `element`. The bounds come only once all were asked (at once).
final class FakeBrowser {
    struct Page { var id: String, title: String, url: String, bounds: String, visible: Bool }
    var pages: [Page]
    var element = ##"{"chain":[{"tag":"button","id":"save","cls":[],"w":100,"h":30,"text":"Save"}],"sel":"#save"}"##
    var evaluateFails = false
    var held: [String] = []
    lazy var channel = ScriptedChannel { [unowned self] id, method, params, session in
        switch method {
        case "Target.getTargets":
            let infos = self.pages.map { #"{"targetId":"\#($0.id)","type":"page","title":"\#($0.title)","url":"\#($0.url)"}"# }
                + [#"{"targetId":"SW","type":"service_worker","title":"","url":"x"}"#]
            return [reply(id, #"{"targetInfos":[\#(infos.joined(separator: ","))]}"#)]
        case "Browser.getWindowForTarget":
            let page = self.pages.first { $0.id == params["targetId"]?.string }
            self.held.append(reply(id, #"{"windowId":1,"bounds":\#(page?.bounds ?? "{}")}"#))
            guard self.held.count == self.pages.count else { return [] }
            defer { self.held = [] }
            return self.held.reversed()
        case "Target.attachToTarget":
            return [#"{"method":"Target.attachedToTarget","params":{}}"#, reply(id, #"{"sessionId":"S-\#(params["targetId"]?.string ?? "")"}"#)]
        case "Runtime.evaluate":
            if self.evaluateFails { return [#"{"id":\#(id),"error":{"message":"Session with given id not found"}}"#] }
            let page = self.pages.first { "S-" + $0.id == session }
            if params["expression"]?.string == CDP.probeScript {
                return [reply(id, #"{"result":{"type":"object","value":{"vis":"\#(page?.visible == true ? "visible" : "hidden")","dpr":1,"iw":1000,"ih":700,"sw":1920,"href":"\#(page?.url ?? "")"}}}"#)]
            }
            let escaped = String(decoding: try! JSONEncoder().encode(JSONValue.string(self.element)), as: UTF8.self)
            return [reply(id, #"{"result":{"type":"string","value":\#(escaped)}}"#)]
        default: return []
        }
    }
    init(_ pages: [Page]) { self.pages = pages }
    var methods: [String] { channel.sent.compactMap { $0["method"]?.string } }
}
