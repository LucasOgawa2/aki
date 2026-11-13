import Foundation

/// Chrome's DevTools Protocol, read-only: where it listens, and the browser's own socket.
extension LinuxMarking {
    public enum CDP {
        /// Where `AKI_CDP_URL` points: only this machine (127.0.0.1).
        public struct Endpoint: Equatable, Sendable {
            public var host: String, port: Int
            public init(host: String, port: Int) {
                self.host = host
                self.port = port
            }
        }

        public static let defaultURL = "http://127.0.0.1:9222"

        /// `AKI_CDP_URL` (default `http://127.0.0.1:9222`) as host and port; `localhost` is
        /// 127.0.0.1; any other host is refused (the page's DOM never leaves the machine).
        public static func endpoint(from value: String?) -> Result<Endpoint, EndpointRefusal> {
            let text = (value?.isEmpty ?? true) ? defaultURL : value!
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "ws"].contains(scheme),
                  let host = url.host?.lowercased()
            else { return .failure(.init(reason: "AKI_CDP_URL isn't a URL like \(defaultURL): \(text)")) }
            guard host == "127.0.0.1" || host == "localhost" else {
                return .failure(.init(reason: "AKI_CDP_URL must be on this machine (127.0.0.1), not \(host)"))
            }
            guard let port = url.port, port > 0, port < 65536 else { return .failure(.init(reason: "AKI_CDP_URL has no port: \(text)")) }
            return .success(.init(host: "127.0.0.1", port: port))
        }

        public struct EndpointRefusal: Error, Equatable, Sendable {
            public var reason: String
        }

        /// The path of `/json/version`'s `webSocketDebuggerUrl` (its host and port are
        /// never used: the connection always goes to the endpoint's).
        public static func browserPath(fromVersion body: [UInt8]) -> String? {
            guard let json = try? JSONDecoder().decode([String: JSONValue].self, from: Data(body)),
                  let url = json["webSocketDebuggerUrl"]?.string.flatMap(URL.init(string:)),
                  url.path.hasPrefix("/devtools/browser/") else { return nil }
            return url.path
        }
    }
}

/// What carries the DevTools messages: a `WebSocketConnection`, or the checks' script.
public protocol MessageChannel: AnyObject {
    func send(_ text: String, until deadline: ContinuousClock.Instant) throws
    func receive(until deadline: ContinuousClock.Instant) throws -> String
    func close()
}

extension LinuxMarking.WebSocketConnection: MessageChannel {}

extension LinuxMarking.CDP {
    public struct Call: Equatable, Sendable {
        public var method: String
        public var params: [String: JSONValue]
        /// A page's session (from `Target.attachToTarget` with `flatten`), else the browser's.
        public var session: String?
        public init(_ method: String, _ params: [String: JSONValue] = [:], session: String? = nil) {
            self.method = method
            self.params = params
            self.session = session
        }
    }

    public enum Answer: Equatable, Sendable {
        case result([String: JSONValue])
        case error(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case channel(String)
        case badMessage
    }

    /// Asks the browser, each call with its own `id`: several at once, the answers
    /// matched by `id` whatever their order; events (no `id`) and answers to calls of an
    /// earlier read that timed out are skipped. Never `Runtime.enable` (no events asked for).
    public final class Client {
        private let channel: MessageChannel
        private var nextID = 1

        public init(channel: MessageChannel) { self.channel = channel }

        public func run(_ calls: [Call], until deadline: ContinuousClock.Instant) throws -> [Answer] {
            var waiting: [Int: Int] = [:]
            for (index, call) in calls.enumerated() {
                let id = nextID
                nextID += 1
                var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(call.method), "params": .object(call.params)]
                if let session = call.session { message["sessionId"] = .string(session) }
                guard let data = try? JSONEncoder().encode(message) else { throw Failure.badMessage }
                do { try channel.send(String(decoding: data, as: UTF8.self), until: deadline) } catch { throw Failure.channel("\(error)") }
                waiting[id] = index
            }
            var answers = [Answer?](repeating: nil, count: calls.count)
            while !waiting.isEmpty {
                let text: String
                do { text = try channel.receive(until: deadline) } catch { throw Failure.channel("\(error)") }
                guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) else { throw Failure.badMessage }
                guard let id = message["id"]?.double.map(Int.init), let index = waiting.removeValue(forKey: id) else { continue }
                if let result = message["result"]?.object {
                    answers[index] = .result(result)
                } else {
                    answers[index] = .error(message["error"]?.object?["message"]?.string ?? "no result")
                }
            }
            return answers.map { $0 ?? .error("no answer") }
        }
    }

    /// A tab, from `Target.getTargets`.
    public struct Target: Equatable, Sendable {
        public var id: String, title: String, url: String
        public init(id: String, title: String, url: String) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    /// The pages (`type: "page"`) of `Target.getTargets`' answer.
    public static func pages(from answer: Answer) -> [Target]? {
        guard case let .result(result) = answer, let infos = result["targetInfos"]?.array else { return nil }
        return infos.compactMap { info in
            guard let info = info.object, info["type"]?.string == "page", let id = info["targetId"]?.string else { return nil }
            return Target(id: id, title: info["title"]?.string ?? "", url: info["url"]?.string ?? "")
        }
    }

    /// `Browser.getWindowForTarget`'s bounds, in Chrome's own pixels (DIP).
    public struct Bounds: Equatable, Sendable {
        public var left: Double, top: Double, width: Double, height: Double
        public init(left: Double, top: Double, width: Double, height: Double) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
        }
    }

    /// Nil when the answer isn't bounds, or the window is minimized.
    public static func bounds(from answer: Answer) -> Bounds? {
        guard case let .result(result) = answer, let b = result["bounds"]?.object, b["windowState"]?.string != "minimized",
              let left = b["left"]?.double, let top = b["top"]?.double, let width = b["width"]?.double, let height = b["height"]?.double
        else { return nil }
        return Bounds(left: left, top: top, width: width, height: height)
    }

    /// The X11 window a mark was made on: in root pixels, absolute, and the invisible
    /// border GTK draws its shadow in (`_GTK_FRAME_EXTENTS`: left, right, top, bottom), if any.
    public struct Window: Equatable, Sendable {
        public var rect: LinuxMarking.Rect
        public var extents: [Double]?
        public init(rect: LinuxMarking.Rect, extents: [Double]? = nil) {
            self.rect = rect
            self.extents = extents
        }
    }

    /// Chrome's pixels per X11 pixel for a window at `bounds`, when they're the same
    /// window: width gives the factor, and the height and the corner must agree with it
    /// (within `tolerance` X11 pixels). The X11 rect is tried without its shadow border
    /// first, then whole. Nil: another window.
    public static func scale(of bounds: Bounds, matching window: Window, tolerance: Double = 4) -> Double? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var rects: [LinuxMarking.Rect] = []
        if let e = window.extents, e.count == 4, e.contains(where: { $0 > 0 }) {
            let r = window.rect
            rects.append(.init(x: r.x + e[0], y: r.y + e[2], width: r.width - e[0] - e[1], height: r.height - e[2] - e[3]))
        }
        rects.append(window.rect)
        for rect in rects where rect.width > 0 {
            let factor = rect.width / bounds.width
            if abs(bounds.height * factor - rect.height) <= tolerance, abs(bounds.left * factor - rect.x) <= tolerance,
               abs(bounds.top * factor - rect.y) <= tolerance { return factor }
        }
        return nil
    }

    /// What a page says of itself (`probeScript`), to pick the tab and place the point.
    public struct Viewport: Equatable, Sendable {
        public var visible: Bool
        public var devicePixelRatio: Double
        public var innerWidth: Double, innerHeight: Double
        /// `screen.width`, in Chrome's pixels.
        public var screenWidth: Double
        public var url: String?
        public init(visible: Bool, devicePixelRatio: Double, innerWidth: Double, innerHeight: Double, screenWidth: Double, url: String? = nil) {
            self.visible = visible
            self.devicePixelRatio = devicePixelRatio
            self.innerWidth = innerWidth
            self.innerHeight = innerHeight
            self.screenWidth = screenWidth
            self.url = url
        }
    }

    /// Read-only: the page's visibility, zoom, viewport, screen and address.
    public static let probeScript = "({vis:document.visibilityState,dpr:window.devicePixelRatio,iw:innerWidth,ih:innerHeight,sw:screen.width,href:location.href})"

    /// `Runtime.evaluate` of `probeScript`, its value checked field by field.
    public static func viewport(from answer: Answer) -> Viewport? {
        // A page's script answers whatever it likes: every field checked.
        guard case let .result(result) = answer, result["exceptionDetails"] == nil, let v = result["result"]?.object?["value"]?.object,
              let visibility = v["vis"]?.string, let dpr = v["dpr"]?.double, dpr > 0, let iw = v["iw"]?.double, let ih = v["ih"]?.double,
              let sw = v["sw"]?.double, sw > 0
        else { return nil }
        return Viewport(visible: visibility == "visible", devicePixelRatio: dpr, innerWidth: iw, innerHeight: ih, screenWidth: sw,
                        url: v["href"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// One of the tabs whose window is the mark's.
    public struct Candidate: Equatable, Sendable {
        public var target: Target
        public var visible: Bool
        public init(target: Target, visible: Bool) {
            self.target = target
            self.visible = visible
        }
    }

    /// The tab the mark was made on: the only one, else the only visible one (the
    /// overlay may have hidden them all), else among those the only one whose title
    /// starts the window's (`_NET_WM_NAME`, "Title - Google Chrome", maybe with the
    /// profile before the browser's name). No single one: none (never a guess).
    public static func pick(_ candidates: [Candidate], windowTitle: String?) -> Target? {
        if candidates.count == 1 { return candidates[0].target }
        let visible = candidates.filter(\.visible)
        if visible.count == 1 { return visible[0].target }
        let pool = visible.isEmpty ? candidates : visible
        guard let windowTitle else { return nil }
        var page = windowTitle
        for suffix in [" - Google Chrome", " - Chromium", " - Brave", " - Microsoft Edge"] {
            if let range = page.range(of: suffix, options: .backwards) {
                page = String(page[..<range.lowerBound])
                break
            }
        }
        let titled = pool.filter { !$0.target.title.isEmpty }
        let exact = titled.filter { $0.target.title == page }
        if exact.count == 1 { return exact[0].target }
        guard exact.isEmpty else { return nil }
        // "Title - Profile": the profile's name after the page's.
        let prefixed = titled.filter { page.hasPrefix($0.target.title + " - ") }
        return prefixed.count == 1 ? prefixed[0].target : nil
    }

    /// Where a root point is in the page, in its CSS pixels: the Mac's formula
    /// (`BrowserProbe` prelude) with `bounds` for the window and `scale` for the Mac's
    /// screen scale; the viewport is taken to sit at the window's bottom-right, so all
    /// of outer minus inner goes to the toolbar above and the left (a DevTools docked
    /// below or on the left, or a side panel, put it elsewhere: wrong there, as on the Mac).
    public enum PagePoint: Equatable, Sendable {
        case inside(x: Double, y: Double, zoom: Double)
        /// On the browser's own bar (tabs, address) or past the page.
        case outside
        /// The page's screen isn't the scale the window gave (`screen.width` against the
        /// monitor's X11 width): the formula would miss.
        case unsure
    }

    public static func pagePoint(_ point: LinuxMarking.Point, bounds: Bounds, scale: Double, viewport: Viewport,
                                 monitorWidth: Double) -> PagePoint {
        guard scale > 0, viewport.devicePixelRatio > 0, viewport.screenWidth > 0 else { return .unsure }
        // The scale again from the page's side (no NSScreen here): the monitor's X11 width over screen.width.
        guard abs(monitorWidth / viewport.screenWidth - scale) / scale < 0.02 else { return .unsure }
        let zoom = viewport.devicePixelRatio / scale
        let vx = bounds.left + (bounds.width - viewport.innerWidth * zoom), vy = bounds.top + (bounds.height - viewport.innerHeight * zoom)
        let x = (point.x / scale - vx) / zoom, y = (point.y / scale - vy) / zoom
        guard x >= 0, y >= 0, x <= viewport.innerWidth, y <= viewport.innerHeight else { return .outside }
        return .inside(x: x, y: y, zoom: zoom)
    }
}
