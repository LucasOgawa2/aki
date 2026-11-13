import Foundation

extension LinuxMarking {
    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The marking overlay's state, without the interface: ported from the Mac's
    /// `MarkingSession` and `MarkingController` (escape, undo, destinations, send).
    /// Differences: one destination for the whole round (the Mac's
    /// `setDestinationForAll`; there each mark keeps its own); it starts on the session
    /// used last, else the first (the Mac uses the tab you just left or the ring you
    /// picked, then the session serving the page: `aki mark` is one-shot, no sidebar; a
    /// mark on a localhost page doesn't move the destination to the session serving it,
    /// as `MarkingSession` does by the mark's `url`: it stays on the one used last);
    /// `warning` says what the Mac says with a beep (GNOME's shortcut drops stderr).
    public struct OverlayState: Equatable, Sendable {
        public private(set) var marks: [PortableMark] = []
        public private(set) var editing: UUID?
        public private(set) var draft = ""
        public private(set) var justMade = false
        public private(set) var sessions: [AgentTerminal]
        public private(set) var destination: String?
        public private(set) var sending = false
        public private(set) var warning: String?

        /// The marks being sent: any later change to the queue keeps to the others.
        public private(set) var batch: Set<UUID> = []
        /// Every session's name seen this round, to name one that closed.
        private var names: [String: String] = [:]
        /// The reads each mark still waits for, by source (its words, its page).
        private var pending: [UUID: Set<Source>] = [:]
        /// The send waiting for them: its token (an older timer never sends) and where it goes.
        private var wait: Wait?
        private struct Wait: Equatable, Sendable {
            var token: Int
            var destination: String
        }
        private var waits = 0

        /// Whether an area's words are read after it's drawn (off when there's no tesseract).
        public let readsText: Bool
        /// Whether a mark on a browser asks its page (off when `AKI_CDP_URL` is refused).
        public let readsPage: Bool

        /// Where a mark's details come from: its words (OCR), its page (DevTools).
        public enum Source: Hashable, Sendable { case text, page }

        public init(sessions: [AgentTerminal], readsText: Bool = false, readsPage: Bool = false) {
            self.sessions = sessions
            self.readsText = readsText
            self.readsPage = readsPage
            for session in sessions { names[session.id] = session.name }
            // The first of those used last (ties, or none known: the list's order).
            destination = sessions.reduce(nil as AgentTerminal?) { best, session in
                best.map { session.lastUsed > $0.lastUsed ? session : $0 } ?? session
            }?.id
        }

        /// Under this, from press to release, a click (as `MarkingView`'s `hypot < 5`).
        public static let clickSlop = 5.0

        public enum Event: Equatable, Sendable {
            /// `onBrowser`: the mark (a point, an area's centre) is in the active window, a browser's.
            case pointer(screen: Int, from: Point, to: Point, app: AppInfo?, onBrowser: Bool = false)
            case draft(String)
            case escape, undo, nextDestination, previousDestination, send
            /// Enter without Ctrl (the Mac's field): a note queues its mark; none (or no card) sends.
            case commit
            case destination(Int)
            case sessionsChanged([AgentTerminal])
            case sendFinished(failed: [UUID], warning: String?)
            /// What was read about a mark (nil fields: nothing, or the read failed).
            case enriched(id: UUID, source: Source = .text, Enrichment)
            /// The time a send waits for the reads is up (the `.wait` with this token).
            case deadline(Int)
        }

        /// What a read brings back; each field fills the mark's own, when there.
        public struct Enrichment: Equatable, Sendable {
            public var text: String?
            public var url: String?
            public var element: PageElement?
            public init(text: String? = nil, url: String? = nil, element: PageElement? = nil) {
                self.text = text
                self.url = url
                self.element = element
            }
        }

        public enum Effect: Equatable, Sendable {
            case send([PortableMark], destination: String)
            case close
            /// Read what's under this mark from each source, then come back with one `.enriched` each.
            case enrich(PortableMark, sources: Set<Source>)
            /// Ctrl+Enter with reads still going: send `.deadline(token)` when the wait is up.
            case wait(token: Int)
        }

        public mutating func handle(_ event: Event) -> Effect? {
            switch event {
            // Answers that come by themselves: the warning is the person's to clear.
            case .sessionsChanged, .sendFinished, .enriched, .deadline: break
            default: warning = nil
            }
            switch event {
            case let .pointer(screen, from, to, app, onBrowser):
                // Not while the marks go (as on the Mac).
                guard !sending else { return nil }
                let moved = ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot()
                let rect = moved < Self.clickSlop
                    ? Rect(x: from.x, y: from.y, width: 0, height: 0)
                    : Rect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                commitDraft()
                let mark = PortableMark(screen: screen, rect: rect, number: marks.count + 1, app: app)
                marks.append(mark)
                editing = mark.id
                justMade = true
                // An area's words (as on the Mac, a point reads none); on a browser, its page
                // too (the element for a point, only the address for an area).
                var sources: Set<Source> = []
                if readsText, !rect.isPoint { sources.insert(.text) }
                if readsPage, onBrowser { sources.insert(.page) }
                if !sources.isEmpty {
                    pending[mark.id] = sources
                    return .enrich(mark, sources: sources)
                }
            case let .draft(text):
                guard editing != nil else { return nil }
                draft = text
                if !text.isEmpty { justMade = false }
            case .escape:
                // Mid-send: it finishes by itself.
                guard !sending else { return nil }
                if editing != nil, draft.isEmpty {
                    cancelEditing()
                } else if editing != nil {
                    draft = ""
                } else {
                    return .close
                }
            case .undo:
                // The last mark, with no card open or on the one just made (nothing typed in it).
                guard !sending, editing == nil || (justMade && draft.isEmpty) else { return nil }
                if editing != nil {
                    cancelEditing()
                } else if !marks.isEmpty {
                    pending[marks.removeLast().id] = nil
                    renumber()
                }
            // Waiting for the reads, the send already has its destination.
            case .nextDestination: if wait == nil { cycleDestination(by: 1) }
            case .previousDestination: if wait == nil { cycleDestination(by: -1) }
            case let .destination(n):
                if wait == nil, n >= 1, n <= sessions.count { destination = sessions[n - 1].id }
            case let .sessionsChanged(open):
                // A closed destination stays: the marks never go elsewhere unasked.
                sessions = open
                for session in open { names[session.id] = session.name }
                if destination == nil, marks.isEmpty { destination = open.first?.id }
            case .commit:
                guard !sending else { return nil }
                if editing != nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    commitDraft()
                    return nil
                }
                return handle(.send)
            case .send:
                guard !sending else { return nil }
                commitDraft()
                guard !marks.isEmpty else { return .close }
                guard !sessions.isEmpty else {
                    warning = "No agent session to send to: open one and mark again."
                    return nil
                }
                guard let destination else {
                    warning = "Choose a session with Tab."
                    return nil
                }
                guard sessions.contains(where: { $0.id == destination }) else {
                    let name = self.destination.flatMap { names[$0] } ?? "That session"
                    warning = "\(name) closed: choose another session with Tab."
                    return nil
                }
                sending = true
                // A read still going (a mark just drawn): the send waits for it, up to a time.
                if marks.contains(where: { pending[$0.id] != nil }) {
                    waits += 1
                    wait = Wait(token: waits, destination: destination)
                    return .wait(token: waits)
                }
                return startSend(to: destination)
            case let .enriched(id, source, enrichment):
                // A mark undone, dropped or sent meanwhile, or this source already in: nothing waits for it.
                guard var sources = pending[id], sources.contains(source) else { return nil }
                if let index = marks.firstIndex(where: { $0.id == id }) {
                    switch source {
                    case .text:
                        if let text = enrichment.text { marks[index].selectedText = text }
                    case .page:
                        if let url = enrichment.url { marks[index].url = url }
                        // An area takes only the address (as on the Mac: an element is a point's).
                        if marks[index].rect.isPoint, let element = enrichment.element { marks[index].element = element }
                    }
                }
                sources.remove(source)
                pending[id] = sources.isEmpty ? nil : sources
                if let wait, !marks.contains(where: { pending[$0.id] != nil }) { return startSend(to: wait.destination) }
            case let .deadline(token):
                guard let wait, wait.token == token else { return nil }
                return startSend(to: wait.destination)
            case let .sendFinished(failed, why):
                guard sending, wait == nil else { return nil }
                sending = false
                // Sent with what they had: a read of theirs arriving now changes nothing.
                for id in batch { pending[id] = nil }
                // What was saved leaves the queue; what wasn't stays, to send again.
                marks.removeAll { batch.contains($0.id) && !failed.contains($0.id) }
                batch = []
                renumber()
                if !failed.isEmpty {
                    let count = failed.count == 1 ? "1 mark couldn't be saved: it's" : "\(failed.count) marks couldn't be saved: they're"
                    warning = [why, "\(count) still here to send again."].compactMap { $0 }.joined(separator: " ")
                    return nil
                }
                if let why {
                    warning = why
                    return nil
                }
                return marks.isEmpty ? .close : nil
            }
            return nil
        }

        /// Waiting for the reads before sending (shown as such; `sending` is true too).
        public var waitingForReads: Bool { wait != nil }

        /// Whether a mark's words (or, later, its page) are still being read.
        public func isPending(_ id: UUID) -> Bool { pending[id] != nil }

        /// The sources a mark still waits for.
        public func pendingSources(_ id: UUID) -> Set<Source> { pending[id] ?? [] }

        private mutating func startSend(to destination: String) -> Effect {
            wait = nil
            batch = Set(marks.map(\.id))
            return .send(marks, destination: destination)
        }

        private mutating func commitDraft() {
            guard let editing, let index = marks.firstIndex(where: { $0.id == editing }) else { return }
            marks[index].comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            self.editing = nil
            draft = ""
            justMade = false
        }

        private mutating func cancelEditing() {
            guard let editing else { return }
            marks.removeAll { $0.id == editing }
            pending[editing] = nil
            self.editing = nil
            draft = ""
            justMade = false
            renumber()
        }

        private mutating func renumber() {
            for index in marks.indices { marks[index].number = index + 1 }
        }

        private mutating func cycleDestination(by step: Int) {
            guard !sessions.isEmpty else { return }
            let index = sessions.firstIndex { $0.id == destination } ?? -1
            destination = sessions[(index + step + sessions.count) % sessions.count].id
        }
    }
}
