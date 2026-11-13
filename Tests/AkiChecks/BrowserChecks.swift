import AkiCore
import Foundation

// The browser's checks (WebSocket, HTTP, DevTools), as functions: one top-level
// main.swift of thousands of lines took the compiler past 6 GB.

typealias WS = LinuxMarking.WebSocket
typealias CDP = LinuxMarking.CDP
/// A deadline a second from whenever it's asked (the scripted ones never wait).
var soon: ContinuousClock.Instant { .now + .seconds(1) }

@MainActor func webSocketChecks() {
    print("linux marking: websocket")
    check(WS.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "the accept value is RFC 6455's own example")
    let opening = String(decoding: WS.handshake(host: "127.0.0.1", port: 9333, path: "/devtools/browser/abc", key: "dGhlIHNhbXBsZSBub25jZQ=="), as: UTF8.self)
    check(opening.hasPrefix("GET /devtools/browser/abc HTTP/1.1\r\n") && opening.contains("\r\nHost: 127.0.0.1:9333\r\n")
          && opening.contains("\r\nUpgrade: websocket\r\n") && opening.contains("\r\nConnection: Upgrade\r\n")
          && opening.contains("\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") && opening.contains("\r\nSec-WebSocket-Version: 13\r\n")
          && opening.hasSuffix("\r\n\r\n"), "the opening request asks for the upgrade with its key")
    check(!opening.lowercased().contains("origin:"), "and sends no Origin (Chrome refuses one it wasn't told to allow)")
    let agreed = Array("HTTP/1.1 101 WebSocket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8)
    check(WS.readHandshake(agreed, key: "dGhlIHNhbXBsZSBub25jZQ==") == .accepted(leftover: []), "101 with the right accept: open")
    check(WS.readHandshake(agreed + [0x81, 0x00], key: "dGhlIHNhbXBsZSBub25jZQ==") == .accepted(leftover: [0x81, 0x00]),
          "the bytes after the headers are kept (the first frame may come with them)")
    check(WS.readHandshake(Array(agreed.prefix(40)), key: "dGhlIHNhbXBsZSBub25jZQ==") == .incomplete, "headers not all there yet: wait")
    check({ if case .refused = WS.readHandshake(agreed, key: "AAAAAAAAAAAAAAAAAAAAAA==") { true } else { false } }(), "another key's accept: refused")
    let forbidden = Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8)
    check(WS.readHandshake(forbidden, key: "dGhlIHNhbXBsZSBub25jZQ==") == .refused("HTTP/1.1 403 Forbidden"), "not 101: refused, with the status line")
    let noUpgrade = Array("HTTP/1.1 101 Switching\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8)
    check({ if case .refused = WS.readHandshake(noUpgrade, key: "dGhlIHNhbXBsZSBub25jZQ==") { true } else { false } }(), "101 without Upgrade: websocket: refused")

    check(WS.frame(.text, payload: Array("Hello".utf8), mask: [0x37, 0xfa, 0x21, 0x3d]) == [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58],
          "a masked text frame is RFC 6455's example byte for byte")
    let mid = WS.frame(.text, payload: [UInt8](repeating: 0x61, count: 256), mask: [0, 0, 0, 0])
    check(mid.prefix(4) == [0x81, 0xFE, 0x01, 0x00] && mid.count == 4 + 4 + 256, "256 bytes: a 16-bit length")
    let big = WS.frame(.text, payload: [UInt8](repeating: 0x61, count: 65536), mask: [0, 0, 0, 0])
    check(big.prefix(10) == [0x81, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0] && big.count == 10 + 4 + 65536, "64 KiB: a 64-bit length")
    check(WS.frame(.pong, payload: [1, 2], mask: [0, 0, 0, 0]) == [0x8A, 0x82, 0, 0, 0, 0, 1, 2], "a pong frame")

    func incoming(_ chunks: [[UInt8]]) -> (messages: [WS.Incoming], failure: WS.Failure?) {
        var reader = WS.Reader(), messages: [WS.Incoming] = []
        do {
            for chunk in chunks {
                reader.feed(chunk)
                while let message = try reader.next() { messages.append(message) }
            }
        } catch let failure as WS.Failure { return (messages, failure) } catch { return (messages, .io("\(error)")) }
        return (messages, nil)
    }
    check(incoming([[0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]]).messages == [.text("Hello")], "an unmasked text frame from the server")
    check(incoming([[0x81], [0x05, 0x48, 0x65], [0x6c, 0x6c, 0x6f]]).messages == [.text("Hello")], "the same frame in pieces")
    check(incoming([[0x01, 0x03, 0x48, 0x65, 0x6c, 0x89, 0x00, 0x80, 0x02, 0x6c, 0x6f]]).messages == [.ping([]), .text("Hello")],
          "a message in fragments, a ping between them: the ping first, then the whole text")
    let wide = [UInt8](repeating: 0x62, count: 70000)
    check(incoming([[0x81, 0x7F, 0, 0, 0, 0, 0, 1, 0x11, 0x70] + wide]).messages == [.text(String(repeating: "b", count: 70000))], "a 64-bit length read")
    check(incoming([[0x81, 0x7E, 0x01, 0x00] + [UInt8](repeating: 0x63, count: 256)]).messages == [.text(String(repeating: "c", count: 256))], "a 16-bit length read")
    check(incoming([[0x89, 0x02, 7, 8], [0x8A, 0x00], [0x88, 0x02, 0x03, 0xE8]]).messages == [.ping([7, 8]), .pong, .close], "ping, pong and close")
    check(incoming([[0x82, 0x01, 0x00]]).failure == .binary, "a binary message: an error (Chrome's are text)")
    check(incoming([[0x83, 0x00]]).failure == .unknownOpcode(3), "an unknown opcode: an error")
    check(incoming([[0x80, 0x01, 0x61]]).failure == .badContinuation, "a continuation with nothing begun: an error")
    check(incoming([[0x01, 0x01, 0x61, 0x81, 0x01, 0x62]]).failure == .badContinuation, "a new text while one is in fragments: an error")
    check(incoming([[0x81, 0x81, 1, 2, 3, 4, 0x61]]).failure == .masked, "a masked frame from the server: an error")
    check(incoming([[0x81, 0x7F, 0, 0, 0, 0, 0, 0x40, 0, 1]]).failure == .tooLarge, "a frame over 4 MB: refused before its bytes come")
    check(incoming([[0x01, 0x7F, 0, 0, 0, 0, 0, 0x30, 0, 0] + [UInt8](repeating: 0x61, count: 0x300000),
                    [0x80, 0x7F, 0, 0, 0, 0, 0, 0x20, 0, 0]]).failure == .tooLarge, "fragments adding up past 4 MB: refused")
    check(incoming([[0x81, 0x02, 0xC3, 0x28]]).failure == .notUTF8, "text that isn't UTF-8: an error")

    print("linux marking: http")
    let get = String(decoding: LinuxMarking.MiniHTTP.get(host: "127.0.0.1", port: 9333, path: "/json/version"), as: UTF8.self)
    check(get == "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:9333\r\nConnection: close\r\n\r\n", "the GET for /json/version")
    let okBody = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=UTF-8\r\ncontent-length: 7\r\n\r\n{\"a\":1}".utf8)
    check(LinuxMarking.MiniHTTP.parse(okBody, closed: false) == .response(status: 200, body: Array("{\"a\":1}".utf8)), "a body as long as its Content-Length")
    check(LinuxMarking.MiniHTTP.parse(Array(okBody.dropLast(2)), closed: false) == .incomplete, "a body still coming: wait")
    check(LinuxMarking.MiniHTTP.parse(Array(okBody.dropLast(2)), closed: true) == .malformed, "closed before the whole body: malformed")
    let noLength = Array("HTTP/1.1 200 OK\r\n\r\n{}".utf8)
    check(LinuxMarking.MiniHTTP.parse(noLength, closed: false) == .incomplete && LinuxMarking.MiniHTTP.parse(noLength, closed: true) == .response(status: 200, body: Array("{}".utf8)),
          "no length: the body ends where the connection does")
    check(LinuxMarking.MiniHTTP.parse(Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), closed: false) == .response(status: 404, body: []), "the status as it came")
    check(LinuxMarking.MiniHTTP.parse(Array("garbage\r\n\r\n".utf8), closed: false) == .malformed, "no status line: malformed")
    check(LinuxMarking.MiniHTTP.parse(Array("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n".utf8), closed: false) == .malformed, "a length over 4 MB: malformed")

    print("linux marking: websocket connection")
    let rfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    func failure(_ body: () throws -> Void) -> WS.Failure? {
        do { try body() } catch let f as WS.Failure { return f } catch { return .io("\(error)") }
        return nil
    }
    let wsStream = ScriptedStream([.bytes(Array(agreed.prefix(30))), .bytes(Array(agreed.dropFirst(30)) + [0x89, 0x01, 0x2A]), .bytes([0x81, 0x02, 0x6F, 0x6B])])
    let ws = try? LinuxMarking.WebSocketConnection(stream: wsStream, host: "127.0.0.1", port: 9333, path: "/devtools/browser/x", until: soon,
                                                   key: rfcKey, mask: { [1, 2, 3, 4] })
    check(ws != nil && wsStream.written.first == WS.handshake(host: "127.0.0.1", port: 9333, path: "/devtools/browser/x", key: rfcKey),
          "connecting writes the opening request and reads the 101 in pieces")
    check((try? ws?.receive(until: soon)) == "ok" && wsStream.written.dropFirst().first == WS.frame(.pong, payload: [0x2A], mask: [1, 2, 3, 4]),
          "a ping before the message: answered with a pong of the same bytes, then the message")
    try? ws?.send("{\"id\":1}", until: soon)
    check(wsStream.written.last == WS.frame(.text, payload: Array("{\"id\":1}".utf8), mask: [1, 2, 3, 4]), "sending writes one masked text frame")
    check(failure { _ = try ws?.receive(until: soon) } == .closed, "the server gone: closed")
    let leftoverStream = ScriptedStream([.bytes(agreed + [0x81, 0x01, 0x61])])
    let leftover = try? LinuxMarking.WebSocketConnection(stream: leftoverStream, host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey)
    check((try? leftover?.receive(until: soon)) == "a", "a frame that came with the 101: read")
    let closing = ScriptedStream([.bytes(agreed + [0x88, 0x00])])
    let closingWS = try? LinuxMarking.WebSocketConnection(stream: closing, host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey)
    check(failure { _ = try closingWS?.receive(until: soon) } == .closed, "a close frame: closed")
    check(failure { _ = try LinuxMarking.WebSocketConnection(stream: ScriptedStream([.bytes(forbidden)]), host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey) }
          == .refused("HTTP/1.1 403 Forbidden"), "a refused handshake: an error with its status line")
    check(failure { _ = try LinuxMarking.WebSocketConnection(stream: ScriptedStream([.bytes(Array(agreed.prefix(20)))]), host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey) }
          == .closed, "closed mid-handshake: closed")
    check(failure { _ = try LinuxMarking.WebSocketConnection(stream: ScriptedStream([.fail(.timedOut)]), host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey) }
          == .timedOut, "no answer in time: timed out")
    let binaryWS = try? LinuxMarking.WebSocketConnection(stream: ScriptedStream([.bytes(agreed + [0x82, 0x00])]), host: "127.0.0.1", port: 1, path: "/", until: soon, key: rfcKey)
    check(failure { _ = try binaryWS?.receive(until: soon) } == .binary, "a binary message: its error")

    let httpStream = ScriptedStream([.bytes(Array(okBody.prefix(50))), .bytes(Array(okBody.dropFirst(50)))])
    let fetched = try? LinuxMarking.MiniHTTP.fetch("/json/version", host: "127.0.0.1", port: 9333, over: httpStream, until: soon)
    check(fetched?.status == 200 && fetched?.body == Array("{\"a\":1}".utf8) && httpStream.written == [LinuxMarking.MiniHTTP.get(host: "127.0.0.1", port: 9333, path: "/json/version")]
          && httpStream.closed, "a GET read in pieces, its connection closed after")
    check(failure { _ = try LinuxMarking.MiniHTTP.fetch("/", host: "127.0.0.1", port: 1, over: ScriptedStream([.bytes(Array("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{}".utf8))]), until: soon) }
          == .io("malformed HTTP response"), "closed before its length: an error")
    check(failure { _ = try LinuxMarking.MiniHTTP.fetch("/", host: "127.0.0.1", port: 1, over: ScriptedStream([.fail(.timedOut)]), until: soon) } == .timedOut,
          "no answer in time: timed out")

}

@MainActor func cdpChecks() {
    print("linux marking: cdp endpoint")
    check(CDP.endpoint(from: nil) == .success(.init(host: "127.0.0.1", port: 9222)), "no AKI_CDP_URL: 127.0.0.1:9222")
    check(CDP.endpoint(from: "http://127.0.0.1:9333") == .success(.init(host: "127.0.0.1", port: 9333)), "AKI_CDP_URL's port")
    check(CDP.endpoint(from: "http://localhost:9333/") == .success(.init(host: "127.0.0.1", port: 9333)), "localhost is 127.0.0.1")
    check(CDP.endpoint(from: "") == .success(.init(host: "127.0.0.1", port: 9222)), "empty: the default")
    check({ if case .failure = CDP.endpoint(from: "http://192.168.0.9:9222") { true } else { false } }(), "another host: refused")
    check({ if case .failure = CDP.endpoint(from: "http://127.0.0.1") { true } else { false } }(), "no port: refused")
    check({ if case .failure = CDP.endpoint(from: "nonsense") { true } else { false } }(), "not a URL: refused")
    let version = Array(#"{"Browser":"HeadlessChrome/154","webSocketDebuggerUrl":"ws://evil.example:1/devtools/browser/5f2c-11"}"#.utf8)
    check(CDP.browserPath(fromVersion: version) == "/devtools/browser/5f2c-11", "only the path of webSocketDebuggerUrl")
    check(CDP.browserPath(fromVersion: Array(#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9/elsewhere"}"#.utf8)) == nil, "a path that isn't DevTools': none")
    check(CDP.browserPath(fromVersion: Array("not json".utf8)) == nil && CDP.browserPath(fromVersion: Array(#"{"webSocketDebuggerUrl":5}"#.utf8)) == nil,
          "not JSON, or not a string: none")

    print("linux marking: cdp client")
    var heldBack: [String] = []
    let clientChannel = ScriptedChannel { id, method, _, _ in
        // The first answer held back until the second call: they come in the other order, with an event and a stale answer between.
        if id == 1 { heldBack = [reply(1, #"{"a":1}"#)]; return [] }
        return [reply(99, "{}"), #"{"method":"Target.targetInfoChanged","params":{}}"#, reply(id, #"{"b":2}"#)] + heldBack
    }
    let cdpClient = CDP.Client(channel: clientChannel)
    let answers = try? cdpClient.run([.init("Target.getTargets"), .init("Runtime.evaluate", ["expression": "1"], session: "S1")], until: soon)
    check(answers == [.result(["a": 1]), .result(["b": 2])], "two calls at once: each answer matched by id, events and stale ids skipped")
    check(clientChannel.sent.map { $0["id"]?.double } == [1, 2] && clientChannel.sent[0]["method"] == "Target.getTargets"
          && clientChannel.sent[0]["params"] == .object([:]) && clientChannel.sent[0]["sessionId"] == nil
          && clientChannel.sent[1]["sessionId"] == "S1" && clientChannel.sent[1]["params"]?.object?["expression"] == "1",
          "each call sent with its id, method, params and the page's session")
    clientChannel.answer = { id, _, _, _ in [#"{"id":\#(id),"error":{"code":-32000,"message":"No target with given id"}}"#] }
    check((try? cdpClient.run([.init("Browser.getWindowForTarget", ["targetId": "gone"])], until: soon)) == [.error("No target with given id")]
          && clientChannel.sent.last?["id"]?.double == 3, "an error answer is that call's, and ids go on across reads")
    clientChannel.answer = { _, _, _, _ in [] }
    check((try? cdpClient.run([.init("Target.getTargets")], until: soon)) == nil, "no answer by the deadline: the read fails")
    clientChannel.answer = { _, _, _, _ in ["not json"] }
    check((try? cdpClient.run([.init("Target.getTargets")], until: soon)) == nil, "an answer that isn't JSON: the read fails")
    check((try? cdpClient.run([], until: soon)) == [], "no calls: nothing sent, nothing waited for")

    print("linux marking: cdp tabs and windows")
    let targetsAnswer = CDP.Answer.result(["targetInfos": [
        ["targetId": "T1", "type": "page", "title": "Inbox", "url": "https://mail.example/"],
        ["targetId": "W1", "type": "service_worker", "title": "sw", "url": "https://mail.example/sw.js"],
        ["targetId": "T2", "type": "page", "title": "", "url": "http://localhost:3000/"],
        ["targetId": 5, "type": "page", "title": "bad", "url": "x"],
    ]])
    check(CDP.pages(from: targetsAnswer) == [.init(id: "T1", title: "Inbox", url: "https://mail.example/"), .init(id: "T2", title: "", url: "http://localhost:3000/")],
          "the pages of getTargets (no workers; one without a string id skipped)")
    check(CDP.pages(from: .error("x")) == nil && CDP.pages(from: .result([:])) == nil, "an error or no targetInfos: none")
    check(CDP.bounds(from: .result(["windowId": 1, "bounds": ["left": 50, "top": 25, "width": 800, "height": 600, "windowState": "normal"]]))
          == .init(left: 50, top: 25, width: 800, height: 600), "a window's bounds")
    check(CDP.bounds(from: .result(["windowId": 1, "bounds": ["left": 0, "top": 0, "width": 800, "height": 600, "windowState": "minimized"]])) == nil
          && CDP.bounds(from: .result(["bounds": ["left": "0"]])) == nil && CDP.bounds(from: .error("no")) == nil, "minimized, malformed or an error: none")
    let win2x = CDP.Window(rect: .init(x: 100, y: 50, width: 1600, height: 1200))
    check(CDP.scale(of: .init(left: 50, top: 25, width: 800, height: 600), matching: win2x) == 2, "the same window at scale 2")
    check(CDP.scale(of: .init(left: 0, top: 0, width: 800, height: 600), matching: .init(rect: .init(x: 0, y: 0, width: 802, height: 598))) != nil,
          "a few pixels off: still it")
    check(CDP.scale(of: .init(left: 50, top: 25, width: 800, height: 550), matching: win2x) == nil, "the height disagrees: another window")
    check(CDP.scale(of: .init(left: 300, top: 25, width: 800, height: 600), matching: win2x) == nil, "same size elsewhere: another window")
    check(CDP.scale(of: .init(left: 50, top: 25, width: 800, height: 600), matching: .init(rect: .init(x: 80, y: 30, width: 1640, height: 1240), extents: [20, 20, 20, 20])) == 2,
          "GTK's shadow border taken off before comparing")
    check(CDP.scale(of: .init(left: 0, top: 0, width: 0, height: 600), matching: win2x) == nil, "no width: none")

    let probeAnswer = CDP.Answer.result(["result": ["type": "object", "value": ["vis": "visible", "dpr": .number(1.25), "iw": 800, "ih": 560, "sw": 1920, "href": "https://a.example/x"]]])
    check(CDP.viewport(from: probeAnswer) == .init(visible: true, devicePixelRatio: 1.25, innerWidth: 800, innerHeight: 560, screenWidth: 1920, url: "https://a.example/x"),
          "what the page says of itself")
    check(CDP.viewport(from: .result(["result": ["type": "object", "value": ["vis": "hidden", "dpr": "2", "iw": 800, "ih": 560, "sw": 1920]]])) == nil,
          "a field of another type: none")
    check(CDP.viewport(from: .result(["result": ["type": "object", "value": ["vis": "hidden", "dpr": 1, "iw": 800, "ih": 560, "sw": 1920]]]))?.visible == false,
          "hidden, no address: still read")
    check(CDP.viewport(from: .result(["result": ["type": "object"], "exceptionDetails": ["text": "x"]])) == nil, "the script threw: none")

    let inbox = CDP.Target(id: "T1", title: "Inbox", url: "u1"), docs = CDP.Target(id: "T2", title: "Docs", url: "u2")
    let docs2 = CDP.Target(id: "T3", title: "Docs 2", url: "u3"), untitled = CDP.Target(id: "T4", title: "", url: "u4")
    check(CDP.pick([.init(target: inbox, visible: false)], windowTitle: nil) == inbox, "one tab in that window: it")
    check(CDP.pick([.init(target: inbox, visible: false), .init(target: docs, visible: true)], windowTitle: "Inbox - Google Chrome") == docs,
          "the visible one first, whatever the title")
    check(CDP.pick([.init(target: inbox, visible: false), .init(target: docs, visible: false)], windowTitle: "Docs - Google Chrome") == docs,
          "all hidden (the overlay): the window's title")
    check(CDP.pick([.init(target: inbox, visible: true), .init(target: docs, visible: true)], windowTitle: "Docs - Work - Google Chrome") == docs,
          "two visible: the title, with the profile's name before the browser's")
    check(CDP.pick([.init(target: docs, visible: false), .init(target: docs2, visible: false)], windowTitle: "Docs 2 - Chromium") == docs2,
          "one title the start of another: the exact one")
    check(CDP.pick([.init(target: docs, visible: false), .init(target: .init(id: "T9", title: "Docs", url: "u9"), visible: false)], windowTitle: "Docs - Google Chrome") == nil,
          "two tabs of the same title: none, no guess")
    check(CDP.pick([.init(target: untitled, visible: false), .init(target: inbox, visible: false)], windowTitle: " - Google Chrome") == nil,
          "a tab without a title matches nothing")
    check(CDP.pick([.init(target: inbox, visible: false), .init(target: docs, visible: false)], windowTitle: nil) == nil, "no window title to tell: none")
    check(CDP.pick([], windowTitle: "Docs - Google Chrome") == nil, "no tab in that window: none")

    let flat = CDP.Viewport(visible: true, devicePixelRatio: 1, innerWidth: 1000, innerHeight: 700, screenWidth: 1920)
    let frame = CDP.Bounds(left: 0, top: 0, width: 1000, height: 800)
    check(CDP.pagePoint(at(500, 150), bounds: frame, scale: 1, viewport: flat, monitorWidth: 1920) == .inside(x: 500, y: 50, zoom: 1),
          "100%: the toolbar's 100 px above the page")
    check(CDP.pagePoint(at(500, 50), bounds: frame, scale: 1, viewport: flat, monitorWidth: 1920) == .outside, "on the toolbar: outside")
    check(CDP.pagePoint(at(1200, 150), bounds: frame, scale: 1, viewport: flat, monitorWidth: 1920) == .outside, "right of the page: outside")
    check(CDP.pagePoint(at(1000, 300), bounds: frame, scale: 2, viewport: .init(visible: true, devicePixelRatio: 2, innerWidth: 1000, innerHeight: 700, screenWidth: 960),
                        monitorWidth: 1920) == .inside(x: 500, y: 50, zoom: 1), "scale 2: X11 pixels halved")
    check(CDP.pagePoint(at(500, 150), bounds: frame, scale: 1, viewport: .init(visible: true, devicePixelRatio: 1.25, innerWidth: 800, innerHeight: 560, screenWidth: 1920),
                        monitorWidth: 1920) == .inside(x: 400, y: 40, zoom: 1.25), "page zoom 125% (in devicePixelRatio)")
    check(CDP.pagePoint(at(600, 400), bounds: .init(left: 100, top: 200, width: 1000, height: 800), scale: 1, viewport: flat, monitorWidth: 1920)
          == .inside(x: 500, y: 100, zoom: 1), "a window away from the corner")
    check(CDP.pagePoint(at(500, 150), bounds: frame, scale: 1, viewport: .init(visible: true, devicePixelRatio: 1, innerWidth: 1000, innerHeight: 700, screenWidth: 960),
                        monitorWidth: 1920) == .unsure, "the page's screen at another scale than the window's: unsure")

    print("linux marking: cdp element")
    let saveJSON = ##"{"chain":[{"tag":"button","id":"save","cls":["primary","big","x3"],"x":1,"y":2,"w":100,"h":30,"text":"Save changes"},{"tag":"form","id":null,"cls":[],"w":400,"h":300,"text":"x"}],"src":"src/App.tsx:12","sel":"#save","html":"<button id=\"save\">Save changes</button>"}"##
    check(CDP.hit(fromResult: saveJSON) == .element(.init(path: "button#save.primary.big “Save changes”", tag: "button", text: "Save changes", id: "save",
          classes: ["primary", "big", "x3"], source: "src/App.tsx:12", html: "<button id=\"save\">Save changes</button>", selector: "#save")),
          "the element as the Mac labels it: tag#id.two classes “its words”")
    let longText = String(repeating: "word ", count: 40)
    let longJSON = #"{"chain":[{"tag":"p","id":"","cls":[],"w":10,"h":10,"text":"\#(longText)"}],"src":"","sel":"","html":"\#(String(repeating: "h", count: 900))"}"#
    let longHit = CDP.hit(fromResult: longJSON)
    check(longHit == .element(.init(path: "p “\(String(longText.prefix(28)))…”", tag: "p", text: String(longText.prefix(80)), id: nil, classes: [], source: nil,
          html: String(repeating: "h", count: 300), selector: nil)), "long words cut (28 in the path, 80, HTML 300); empty id, source, selector: none")
    check(CDP.hit(fromResult: #"{"chain":[{"tag":"i","cls":[],"w":2,"h":2,"text":"x"},{"tag":"a","id":7,"cls":["link",3],"w":50,"h":20,"text":"x"}],"sel":"a"}"#)
          == .element(.init(path: "a.link", tag: "a", text: "x", id: nil, classes: ["link"], selector: "a")),
          "a speck too small skipped for the next one up; values of the wrong type dropped; one letter isn't quoted")
    check(CDP.hit(fromResult: #"{"outside":true}"#) == .outside && CDP.hit(fromResult: #"{"background":true}"#) == .background, "outside and background")
    check(CDP.hit(fromResult: "{}") == .none && CDP.hit(fromResult: "nonsense") == .none && CDP.hit(fromResult: #"{"chain":[]}"#) == .none
          && CDP.hit(fromResult: #"{"error":"TypeError"}"#) == .none, "nothing, garbage, an empty chain or the script's error: none")
    check(CDP.hit(fromResult: #"{"chain":[{"tag":"\#(String(repeating: "t", count: 500))","cls":[],"w":9,"h":9}],"src":"\#(String(repeating: "s", count: 500))"}"#)
          .element?.path.count == 300 && CDP.hit(fromResult: #"{"chain":[{"tag":"b","cls":[],"w":9,"h":9}],"src":"\#(String(repeating: "s", count: 500))"}"#).element?.source?.count == 300,
          "a huge tag or source: cut at 300")
    let script = CDP.elementScript(x: 12.5, y: 40, zoom: 1.25)
    check(script.hasPrefix("(function(px,py,Z){") && script.hasSuffix("})(12.5,40,1.25)"), "the extraction is one function called with the point and zoom")
    check(script.contains(#"/rgba\(.*,\s*0\)$/"#) && script.contains(#".replace(/\s+/g,' ')"#), "its regexes reach the page with one backslash")
    check(!script.contains("window.__aki") && !script.contains(".click(") && !script.contains("location=") && !script.contains(".focus("),
          "no window.__aki*, and nothing that clicks, focuses or navigates")
    check(script.contains("__akiPoint=[x,y]") && script.contains("var p=__akiPoint"), "deep() leaves the point for result()'s caret check")

}

@MainActor func pageReaderChecks() {
    print("linux marking: cdp page reader")
    let here = #"{"left":0,"top":0,"width":1000,"height":800,"windowState":"normal"}"#
    let elsewhere = #"{"left":1000,"top":0,"width":900,"height":800,"windowState":"normal"}"#
    let chromeWindow = CDP.Window(rect: .init(x: 0, y: 0, width: 1000, height: 800))
    let browser = FakeBrowser([.init(id: "T1", title: "App", url: "http://localhost:3000/", bounds: here, visible: true),
                               .init(id: "T2", title: "Mail", url: "https://mail.example/", bounds: elsewhere, visible: true)])
    var connects = 0
    let pageReader = CDP.PageReader { _ in connects += 1; return browser.channel }
    let firstRead = pageReader.read(window: chromeWindow, title: "App - Google Chrome", point: at(500, 150), monitorWidth: 1920, until: soon)
    check(firstRead == .init(url: "http://localhost:3000/", element: .init(path: "button#save “Save”", tag: "button", text: "Save", id: "save", selector: "#save")),
          "a point on the page: the tab of that window, its address and the element")
    check(browser.methods == ["Target.getTargets", "Browser.getWindowForTarget", "Browser.getWindowForTarget", "Target.attachToTarget", "Runtime.evaluate", "Runtime.evaluate"],
          "the windows asked at once; only the tab in the mark's window attached; never Runtime.enable")
    let attach = browser.channel.sent.first { $0["method"] == "Target.attachToTarget" }?["params"]?.object
    let extract = browser.channel.sent.last?["params"]?.object
    check(attach?["targetId"] == "T1" && attach?["flatten"] == .bool(true), "attached flat, to its own session")
    check(extract?["returnByValue"] == .bool(true) && extract?["silent"] == .bool(true) && extract?["contextId"] == nil
          && extract?["expression"]?.string == CDP.elementScript(x: 500, y: 50, zoom: 1) && browser.channel.sent.last?["sessionId"] == "S-T1",
          "the extraction by value, silent, in the page's main world, at the page's point")
    let before = browser.channel.sent.count
    let secondRead = pageReader.read(window: chromeWindow, title: "App - Google Chrome", point: nil, monitorWidth: 1920, until: soon)
    check(secondRead == .init(url: "http://localhost:3000/") && browser.methods.dropFirst(before) == ["Runtime.evaluate"] && connects == 1,
          "the next mark (an area): the same tab, only its address asked again")
    let toolbar = pageReader.read(window: chromeWindow, title: nil, point: at(500, 50), monitorWidth: 1920, until: soon)
    check(toolbar == .init(url: "http://localhost:3000/") && browser.methods.last == "Runtime.evaluate" && browser.channel.sent.last?["params"]?.object?["expression"]?.string == CDP.probeScript,
          "a point on the tabs bar: the address, no element asked")
    browser.element = #"{"background":true}"#
    check(pageReader.read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 1920, until: soon) == .init(url: "http://localhost:3000/"),
          "empty space: the address, no element")
    browser.element = "garbage"
    check(pageReader.read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 1920, until: soon) == .init(url: "http://localhost:3000/"),
          "an answer that isn't one: the address, no element")
    check(pageReader.read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 960, until: soon) == .init(url: "http://localhost:3000/"),
          "unsure of the scale: the address, no element")

    let tabs = FakeBrowser([.init(id: "A", title: "Inbox", url: "https://a/", bounds: here, visible: false),
                            .init(id: "B", title: "Docs", url: "https://b/", bounds: here, visible: false)])
    let tabsReader = CDP.PageReader { _ in tabs.channel }
    check(tabsReader.read(window: chromeWindow, title: "Docs - Google Chrome", point: nil, monitorWidth: 1920, until: soon) == .init(url: "https://b/")
          && tabs.methods.filter { $0 == "Target.attachToTarget" }.count == 2, "two tabs in the window, both hidden: the window's title tells")
    let twins = FakeBrowser([.init(id: "A", title: "Docs", url: "https://a/", bounds: here, visible: false),
                             .init(id: "B", title: "Docs", url: "https://b/", bounds: here, visible: false)])
    check(CDP.PageReader { _ in twins.channel }.read(window: chromeWindow, title: "Docs - Google Chrome", point: at(500, 150), monitorWidth: 1920, until: soon) == .init()
          && twins.methods.filter { $0 == "Runtime.evaluate" }.count == 2,
          "two twin tabs: nothing, not even the address, no element asked")
    let away = FakeBrowser([.init(id: "A", title: "X", url: "https://a/", bounds: elsewhere, visible: true)])
    check(CDP.PageReader { _ in away.channel }.read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 1920, until: soon) == .init()
          && !away.methods.contains("Target.attachToTarget"), "no page in the mark's window: nothing, nothing attached")
    check(CDP.PageReader { _ in throw LinuxMarking.WebSocket.Failure.io("Connection refused") }
          .read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 1920, until: soon) == .init(), "no browser listening: nothing")
    let mute = ScriptedChannel { _, _, _, _ in [] }
    check(CDP.PageReader { _ in mute }.read(window: chromeWindow, title: nil, point: at(500, 150), monitorWidth: 1920, until: soon) == .init() && mute.closed,
          "a browser that never answers: nothing, and its connection dropped")
    let closedTab = FakeBrowser([.init(id: "T1", title: "App", url: "http://localhost:3000/", bounds: here, visible: true)])
    var closedConnects = 0
    let closedReader = CDP.PageReader { _ in closedConnects += 1; return closedTab.channel }
    _ = closedReader.read(window: chromeWindow, title: nil, point: nil, monitorWidth: 1920, until: soon)
    closedTab.evaluateFails = true
    let afterClose = closedReader.read(window: chromeWindow, title: nil, point: nil, monitorWidth: 1920, until: soon)
    check(afterClose == .init(url: "http://localhost:3000/") && closedConnects == 2 && closedTab.methods.filter { $0 == "Target.getTargets" }.count == 2,
          "the kept tab's session gone: found again from the start (its address from the listing)")

}
