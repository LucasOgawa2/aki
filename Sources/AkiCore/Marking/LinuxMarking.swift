import Foundation

/// Marking on Linux, without the interface: what a mark records, its crop, the X11
/// pixels, how the marks reach the session and the overlay's state. The Mac's own
/// types (`Mark`, `MarkContext`, `identityFields`…) live in the app target, which
/// doesn't build on Linux; these are portable copies under their own names.
public enum LinuxMarking {
    /// In X11 pixels (scale 1), top-left origin within its monitor.
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// As the Mac's `Mark.isPoint`: a click, not a drag.
        public var isPoint: Bool { width < 1 && height < 1 }
    }

    /// The window a mark was made on (X11's `WM_CLASS` / `_NET_WM_NAME`, read by the overlay).
    public struct AppInfo: Equatable, Sendable {
        public var name: String?
        public var window: String?

        public init(name: String? = nil, window: String? = nil) {
            self.name = name
            self.window = window
        }
    }

    /// One mark of a round: a point or an area on one monitor, and its comment.
    public struct PortableMark: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var screen: Int
        public var rect: Rect
        public var comment: String
        public var number: Int
        public var app: AppInfo?

        public init(id: UUID = UUID(), screen: Int, rect: Rect, comment: String = "", number: Int, app: AppInfo? = nil) {
            self.id = id
            self.screen = screen
            self.rect = rect
            self.comment = comment
            self.number = number
            self.app = app
        }
    }

    /// The time and the random part of new ids, injectable for the checks.
    public struct Clock: Sendable {
        public var now: @Sendable () -> Date
        public var random: @Sendable () -> String

        public init(now: @escaping @Sendable () -> Date, random: @escaping @Sendable () -> String) {
            self.now = now
            self.random = random
        }

        public static let system = Clock(now: { Date() }, random: { String(UUID().uuidString.prefix(8)).lowercased() })
    }
}

extension LinuxMarking {
    /// A session as the listing gives it, made by hand (the checks, a fixture).
    public static func terminal(
        id: String, agent: AgentSession.Agent = .claude, pid: Int32 = 0, name: String, worktree: String,
        state: AgentTerminal.State = .idle, orcaHandle: String? = nil, lastSent: Date? = nil, updatedAt: Date? = nil
    ) -> AgentTerminal {
        var terminal = AgentTerminal(
            id: id, agent: agent, pid: pid, name: name, named: true, worktree: worktree, branch: nil, state: state,
            lastMessage: nil, pending: 0, pendingComments: [], updatedAt: updatedAt)
        terminal.orcaHandle = orcaHandle
        terminal.lastSent = lastSent
        return terminal
    }
}
