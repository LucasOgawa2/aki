import Foundation

/// How a round's marks reach their session on Linux, ported from the terminal path of
/// the Mac's `SidebarModel.send` (Sources/Aki/Sidebar/SidebarModel.swift). Differences:
/// - typed at once (the Mac's "send now"); a session asking something holds them, and
///   they go with the next send (the Mac sends them by itself once it's answered);
/// - only Orca tabs, found by the session's own handle, never by folder or title.
extension LinuxMarking {
    public enum DeliveryOutcome: Equatable, Sendable {
        /// Saved and typed into the session's tab.
        case sent
        /// Saved; the session is asking something, so nothing was typed.
        case held(String)
        /// Saved; it couldn't be typed (no Orca tab, no orca-ide).
        case notTyped(String)
        /// Saved; Orca didn't answer the send in time, so it may have been typed.
        case uncertain(String)
        /// Saved; Orca refused to type it.
        case typingFailed(String)
        /// Nothing saved, nothing typed.
        case notSaved(String)

        /// What to tell the person (nil when it all went).
        public var warning: String? {
            switch self {
            case .sent: nil
            case .held(let why), .notTyped(let why), .uncertain(let why), .typingFailed(let why), .notSaved(let why): why
            }
        }
    }

    public struct DeliveryReport: Sendable {
        public var outcome: DeliveryOutcome
        /// Saved in the store (whatever happened to the typing).
        public var saved: [Annotation] = []
        /// Not saved: they stay in the queue.
        public var failed: [UUID] = []
        /// The message typed, when one was.
        public var prompt: String?
    }

    /// Saves `marks` for `destination`, then types the message into its Orca tab once.
    /// `sessions` is a listing taken now (whether it's asking something is read there).
    public static func deliver(
        _ marks: [PortableMark], to destination: String?, sessions: [AgentTerminal], jpeg: (PortableMark) -> Data?,
        store: AnnotationStore, home: AkiHome, orca: (any OrcaRunner)?, aki: String, clock: Clock = .system
    ) async -> DeliveryReport {
        let all = marks.map(\.id)
        guard !sessions.isEmpty else {
            return DeliveryReport(outcome: .notSaved("No agent session to send to: nothing was saved."), failed: all)
        }
        guard let terminal = sessions.first(where: { $0.id == destination }) else {
            return DeliveryReport(outcome: .notSaved("That session closed: choose another. Nothing was saved."), failed: all)
        }
        let saving = await save(marks, to: terminal, jpeg: jpeg, store: store, home: home, clock: clock)
        var report = DeliveryReport(outcome: .sent, saved: saving.saved, failed: saving.failed)
        guard !saving.saved.isEmpty else {
            report.outcome = .notSaved(marks.count == 1 ? "The mark couldn't be saved: nothing was sent." : "The marks couldn't be saved: nothing was sent.")
            return report
        }
        let name = terminal.name
        // Asking you something in its terminal: typing there would answer it.
        guard terminal.state != .waiting else {
            report.outcome = .held(saving.saved.count == 1
                ? "\(name) is asking you something: the mark is saved and goes with your next send."
                : "\(name) is asking you something: the \(saving.saved.count) marks are saved and go with your next send.")
            return report
        }
        guard let handle = terminal.orcaHandle else {
            report.outcome = .notTyped("Saved for \(name), not typed: it isn't in an Orca tab. Its agent finds them with `\(aki) list`.")
            return report
        }
        guard let orca else {
            report.outcome = .notTyped("Saved for \(name), not typed: orca-ide wasn't found.")
            return report
        }
        // Only its own tab, in its own folder (as the Mac's `orcaTab(for:)` with a handle).
        guard case .exited(0, let listed) = orca.run(["terminal", "list", "--json", "--limit", "200"]),
              let json = try? JSONSerialization.jsonObject(with: listed) as? [String: Any], json["ok"] as? Bool != false,
              let tabs = (json["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
        else {
            report.outcome = .notTyped("Saved for \(name), not typed: Orca didn't list its tabs.")
            return report
        }
        guard tabs.contains(where: { ($0["handle"] as? String) == handle && holds($0, terminal) }) else {
            report.outcome = .notTyped("Saved for \(name), not typed: Orca has no tab \(handle) in its folder.")
            return report
        }
        // The marks this message is about, from one look at the store.
        let pending = await pendingMarks(of: terminal, in: store)
        let waiting = pending.filter { $0["delivered_at"]?.string == nil }.map(\.id)
        let oldestFirst = pending.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
            .filter { waiting.isEmpty || waiting.contains($0.id) }
        var current = terminal
        current.pendingIDs = oldestFirst.map(\.id)
        current.pendingComments = oldestFirst.reversed().prefix(3).map {
            $0["comment"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "(no text)"
        }
        current.pending = oldestFirst.count
        current.undelivered = waiting.count
        current.pendingPlaces = places(of: pending)
        let prompt = deliveryPrompt(for: current, aki: aki)
        report.prompt = prompt
        let typed = orca.run(sendArguments(handle: handle, prompt: prompt))
        if case .timedOut = typed {
            report.outcome = .uncertain("Saved for \(name). Orca didn't answer in time: the message may have been typed, so it isn't sent again.")
        } else if case .exited(0, let answer) = typed,
                  (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["ok"] as? Bool != false {
            // (An answer that isn't JSON but ended well counts as sent, as on the Mac.)
            await markDelivered(waiting, for: terminal, in: store, at: clock.now())
            report.outcome = .sent
        } else {
            report.outcome = .typingFailed("Saved for \(name), but Orca didn't type the message.")
        }
        return report
    }

    /// The tab's folder is the session's, or holds it (the Mac's `TerminalJump.holds`).
    static func holds(_ tab: [String: Any], _ terminal: AgentTerminal) -> Bool {
        guard let path = tab["worktreePath"] as? String else { return false }
        return terminal.worktree == path || terminal.worktree.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    /// Where the marks were made, once each (the listing's `pendingPlaces`).
    static func places(of marks: [Annotation]) -> [String] {
        var seen: [String] = []
        for a in marks {
            let place: String? = a["url"]?.string.flatMap(URL.init(string:)).flatMap { u in
                u.host().map { $0 + (u.port.map { ":\($0)" } ?? "") }
            } ?? a["app"]?.object?["name"]?.string
            if let place, !seen.contains(place) { seen.append(place) }
        }
        return seen
    }

    /// The session's pending marks, as the store has them now.
    static func pendingMarks(of terminal: AgentTerminal, in store: AnnotationStore) async -> [Annotation] {
        await store.list(.init(status: "pending")).annotations.filter { annotation in
            annotation["session_id"]?.string == terminal.id
                || (annotation["session_id"] == nil && annotation["worktree"]?.string == terminal.worktree)
        }
    }

    /// Written on the marks themselves; only those still this session's.
    static func markDelivered(_ ids: [String], for terminal: AgentTerminal, in store: AnnotationStore, at date: Date) async {
        let now = ISO8601DateFormatter().string(from: date)
        let wanted = Set(ids)
        for annotation in await pendingMarks(of: terminal, in: store) where wanted.contains(annotation.id) {
            _ = try? await store.update(annotation.id, with: ["delivered_at": .string(now)])
        }
    }
}
