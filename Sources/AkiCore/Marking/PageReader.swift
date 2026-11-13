import Foundation

extension LinuxMarking.CDP {
    /// What a mark gets from the browser: the tab's address, and for a point the element under it.
    public struct PageRead: Equatable, Sendable {
        public var url: String?
        public var element: LinuxMarking.PageElement?
        public init(url: String? = nil, element: LinuxMarking.PageElement? = nil) {
            self.url = url
            self.element = element
        }
    }

    /// Reads marks' pages for one round of `aki mark`, one at a time (not thread-safe:
    /// the overlay calls it from one queue). The first read finds the tab: the pages
    /// whose window is the mark's (`getWindowForTarget`, all asked at once), then the
    /// visible one, then the title (`pick`); that tab, its session and scale are kept
    /// for the next marks (the screen is frozen: same window). Anything failing, or the
    /// deadline: what's known so far (never a guess).
    public final class PageReader {
        private let connect: (ContinuousClock.Instant) throws -> MessageChannel
        private var channel: MessageChannel?
        private var client: Client?
        private var chosen: Chosen?

        private struct Chosen {
            var target: Target
            var session: String
            var bounds: Bounds
            var scale: Double
        }

        /// `connect`: `/json/version`, then the browser's WebSocket, by the deadline.
        public init(connect: @escaping (ContinuousClock.Instant) throws -> MessageChannel) {
            self.connect = connect
        }

        /// `point`: the mark's, in root pixels (nil for an area: only the address).
        /// `monitorWidth`: the X11 width of the monitor it's on, in pixels.
        public func read(window: Window, title: String?, point: LinuxMarking.Point?, monitorWidth: Double,
                         until deadline: ContinuousClock.Instant) -> PageRead {
            // A kept tab whose session went (closed, the browser restarted): found again, once.
            for attempt in 0..<2 {
                let kept = chosen != nil
                switch readOnce(window: window, title: title, point: point, monitorWidth: monitorWidth, until: deadline) {
                case let .done(read): return read
                case let .failed(known):
                    close()
                    guard kept, attempt == 0, ContinuousClock.now < deadline else { return known }
                }
            }
            return PageRead()
        }

        private enum Outcome {
            case done(PageRead)
            /// The connection or the kept session failed; `known`: what was read before.
            case failed(known: PageRead)
        }

        private func readOnce(window: Window, title: String?, point: LinuxMarking.Point?, monitorWidth: Double,
                              until deadline: ContinuousClock.Instant) -> Outcome {
            do {
                let client: Client
                if let open = self.client {
                    client = open
                } else {
                    let channel = try connect(deadline)
                    self.channel = channel
                    client = Client(channel: channel)
                    self.client = client
                }
                let tab: Chosen, viewport: Viewport?
                if let chosen {
                    guard let probed = LinuxMarking.CDP.viewport(from: try client.run([probe(chosen.session)], until: deadline)[0]) else {
                        return .failed(known: PageRead())
                    }
                    tab = chosen
                    viewport = probed
                } else {
                    guard let found = try find(window: window, title: title, client: client, until: deadline) else { return .done(PageRead()) }
                    tab = found.tab
                    viewport = found.viewport
                    chosen = found.tab
                }
                var read = PageRead(url: viewport?.url ?? (tab.target.url.isEmpty ? nil : tab.target.url))
                guard let point, let viewport,
                      case let .inside(x, y, zoom) = LinuxMarking.CDP.pagePoint(point, bounds: tab.bounds, scale: tab.scale, viewport: viewport, monitorWidth: monitorWidth)
                else { return .done(read) }
                let answer = try client.run([evaluate(LinuxMarking.CDP.elementScript(x: x, y: y, zoom: zoom), session: tab.session)], until: deadline)[0]
                if case let .result(result) = answer, result["exceptionDetails"] == nil,
                   let text = result["result"]?.object?["value"]?.string {
                    read.element = LinuxMarking.CDP.hit(fromResult: text).element
                }
                return .done(read)
            } catch {
                return .failed(known: chosen.map { PageRead(url: $0.target.url.isEmpty ? nil : $0.target.url) } ?? PageRead())
            }
        }

        /// The tab of `window`, attached, with what it says of itself; nil: none, or not just one.
        private func find(window: Window, title: String?, client: Client, until deadline: ContinuousClock.Instant) throws
            -> (tab: Chosen, viewport: Viewport?)? {
            guard let pages = LinuxMarking.CDP.pages(from: try client.run([Call("Target.getTargets")], until: deadline)[0]), !pages.isEmpty else { return nil }
            let windows = try client.run(pages.map { Call("Browser.getWindowForTarget", ["targetId": .string($0.id)]) }, until: deadline)
            let here: [(Target, Bounds, Double)] = zip(pages, windows).compactMap { page, answer in
                guard let bounds = LinuxMarking.CDP.bounds(from: answer), let scale = LinuxMarking.CDP.scale(of: bounds, matching: window) else { return nil }
                return (page, bounds, scale)
            }
            guard !here.isEmpty else { return nil }
            let attached = try client.run(here.map { Call("Target.attachToTarget", ["targetId": .string($0.0.id), "flatten": true]) }, until: deadline)
            let sessions = attached.map { answer -> String? in
                if case let .result(result) = answer { return result["sessionId"]?.string }
                return nil
            }
            let open = zip(here, sessions).compactMap { tab, session in session.map { (tab, $0) } }
            guard open.count == here.count else { return nil }
            let probes = try client.run(open.map { probe($0.1) }, until: deadline).map(LinuxMarking.CDP.viewport(from:))
            // A tab that didn't say whether it's visible counts as hidden.
            let candidates = zip(open, probes).map { Candidate(target: $0.0.0, visible: $1?.visible ?? false) }
            guard let target = LinuxMarking.CDP.pick(candidates, windowTitle: title),
                  let index = open.firstIndex(where: { $0.0.0 == target }) else { return nil }
            let ((_, bounds, scale), session) = open[index]
            return (Chosen(target: target, session: session, bounds: bounds, scale: scale), probes[index])
        }

        private func probe(_ session: String) -> Call { evaluate(LinuxMarking.CDP.probeScript, session: session) }

        /// In the page's main world (no `contextId`: React's `__reactFiber` isn't in an isolated one).
        private func evaluate(_ expression: String, session: String) -> Call {
            Call("Runtime.evaluate", ["expression": .string(expression), "returnByValue": true, "silent": true], session: session)
        }


        public func close() {
            channel?.close()
            channel = nil
            client = nil
            chosen = nil
        }
    }
}
