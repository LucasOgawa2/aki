import AkiCore
import Foundation

/// Chrome's DevTools on this machine: `/json/version` for the browser's socket, then
/// that WebSocket, both to `AKI_CDP_URL`'s port on 127.0.0.1 (the host in Chrome's
/// answer is never used).
enum Browser {
    static func connect(to endpoint: LinuxMarking.CDP.Endpoint, until deadline: ContinuousClock.Instant) throws -> MessageChannel {
        let http = try LoopbackStream(port: endpoint.port, until: deadline)
        let version = try LinuxMarking.MiniHTTP.fetch("/json/version", host: endpoint.host, port: endpoint.port, over: http, until: deadline)
        guard version.status == 200, let path = LinuxMarking.CDP.browserPath(fromVersion: version.body) else {
            throw LinuxMarking.WebSocket.Failure.refused("/json/version answered \(version.status) without a browser socket")
        }
        let stream = try LoopbackStream(port: endpoint.port, until: deadline)
        do {
            return try LinuxMarking.WebSocketConnection(stream: stream, host: endpoint.host, port: endpoint.port, path: path, until: deadline)
        } catch {
            stream.close()
            throw error
        }
    }

    /// Not for people (`aki-mark --probe-cdp [x y]`): each page's window bounds and what it
    /// says of itself, then the element at the CSS point x, y of the first page.
    static func probe(_ arguments: [String], environment: [String: String]) -> Int32 {
        let endpoint: LinuxMarking.CDP.Endpoint
        switch LinuxMarking.CDP.endpoint(from: environment["AKI_CDP_URL"]) {
        case let .success(found): endpoint = found
        case let .failure(refusal):
            print("refused: \(refusal.reason)")
            return 1
        }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        do {
            let channel = try connect(to: endpoint, until: deadline)
            defer { channel.close() }
            print("connected \(endpoint.host):\(endpoint.port)")
            let client = LinuxMarking.CDP.Client(channel: channel)
            let pages = LinuxMarking.CDP.pages(from: try client.run([.init("Target.getTargets")], until: deadline)[0]) ?? []
            let windows = try client.run(pages.map { .init("Browser.getWindowForTarget", ["targetId": .string($0.id)]) }, until: deadline)
            let attached = try client.run(pages.map { .init("Target.attachToTarget", ["targetId": .string($0.id), "flatten": true]) }, until: deadline)
            let sessions = attached.map { answer -> String? in
                if case let .result(r) = answer { return r["sessionId"]?.string }
                return nil
            }
            let probes = try client.run(sessions.map {
                .init("Runtime.evaluate", ["expression": .string(LinuxMarking.CDP.probeScript), "returnByValue": true, "silent": true], session: $0)
            }, until: deadline)
            for (i, page) in pages.enumerated() {
                print("page \(page.id) title \"\(page.title)\" url \(page.url)")
                print("  window \(windows[i])")
                print("  bounds \(LinuxMarking.CDP.bounds(from: windows[i]).map { "\($0)" } ?? "none")")
                print("  viewport \(LinuxMarking.CDP.viewport(from: probes[i]).map { "\($0)" } ?? "none")")
            }
            if arguments.count == 2, let x = Double(arguments[0]), let y = Double(arguments[1]), let session = sessions.first ?? nil {
                let answer = try client.run([.init("Runtime.evaluate", ["expression": .string(LinuxMarking.CDP.elementScript(x: x, y: y, zoom: 1)),
                                                                         "returnByValue": true, "silent": true], session: session)], until: deadline)[0]
                if case let .result(r) = answer, let text = r["result"]?.object?["value"]?.string {
                    print("raw \(text)")
                    print("hit \(LinuxMarking.CDP.hit(fromResult: text))")
                } else {
                    print("evaluate \(answer)")
                }
            }
            return 0
        } catch {
            print("failed: \(error)")
            return 1
        }
    }
}
