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
    /// picked, then the session serving the page: `aki mark` is one-shot, no sidebar);
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

        public init(sessions: [AgentTerminal]) {
            self.sessions = sessions
            for session in sessions { names[session.id] = session.name }
            // The first of those used last (ties, or none known: the list's order).
            destination = sessions.reduce(nil as AgentTerminal?) { best, session in
                best.map { session.lastUsed > $0.lastUsed ? session : $0 } ?? session
            }?.id
        }

        /// Under this, from press to release, a click (as `MarkingView`'s `hypot < 5`).
        public static let clickSlop = 5.0

        public enum Event: Equatable, Sendable {
            case pointer(screen: Int, from: Point, to: Point, app: AppInfo?)
            case draft(String)
            case escape, undo, nextDestination, previousDestination, send
            /// Enter without Ctrl (the Mac's field): a note queues its mark; none (or no card) sends.
            case commit
            case destination(Int)
            case sessionsChanged([AgentTerminal])
            case sendFinished(failed: [UUID], warning: String?)
        }

        public enum Effect: Equatable, Sendable {
            case send([PortableMark], destination: String)
            case close
        }

        public mutating func handle(_ event: Event) -> Effect? {
            switch event {
            case .sessionsChanged, .sendFinished: break
            default: warning = nil
            }
            switch event {
            case let .pointer(screen, from, to, app):
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
                    marks.removeLast()
                    renumber()
                }
            case .nextDestination: cycleDestination(by: 1)
            case .previousDestination: cycleDestination(by: -1)
            case let .destination(n):
                if n >= 1, n <= sessions.count { destination = sessions[n - 1].id }
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
                batch = Set(marks.map(\.id))
                return .send(marks, destination: destination)
            case let .sendFinished(failed, why):
                guard sending else { return nil }
                sending = false
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
