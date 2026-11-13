import Foundation

extension LinuxMarking {
    /// The sessions a round can go to, listed now. With `AKI_DRY_DELIVER=1` (an end-to-end
    /// check) they come from `$AKI_HOME/dry-sessions.json` only, never the real ones: a list
    /// of `{"id","name","worktree"}` with optional `"agent"`, `"state"`, `"orcaHandle"`,
    /// `"lastSent"` (seconds since 1970). No file, or one it can't read: zero sessions.
    public static func sessions(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: AkiHome = .default,
        live: () -> [AgentTerminal]
    ) -> [AgentTerminal] {
        guard environment["AKI_DRY_DELIVER"] == "1" else { return live() }
        guard let data = try? Data(contentsOf: home.url.appending(path: "dry-sessions.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String, let worktree = entry["worktree"] as? String
            else { return nil }
            return terminal(
                id: id, agent: (entry["agent"] as? String).flatMap(AgentSession.Agent.init(rawValue:)) ?? .claude, name: name,
                worktree: worktree, state: (entry["state"] as? String).flatMap(AgentTerminal.State.init(rawValue:)) ?? .idle,
                orcaHandle: entry["orcaHandle"] as? String,
                lastSent: (entry["lastSent"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
    }
}
