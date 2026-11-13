import Foundation

/// Runs `gsettings` with these arguments: the real one, or the checks' fake.
public protocol GSettingsRunner: Sendable {
    func run(_ arguments: [String]) -> Command.Outcome
}

/// `aki shortcut install|remove`: GNOME's custom keyboard shortcut for `aki mark`,
/// ⇧ Super A, kept at its own path beside the ones you already have.
public enum GnomeShortcut {
    public static let listSchema = "org.gnome.settings-daemon.plugins.media-keys"
    public static let listKey = "custom-keybindings"
    public static let path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/aki/"
    public static let itemSchema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:" + path
    public static let name = "Aki"
    public static let binding = "<Shift><Super>a"

    /// What GNOME runs: gsd splits it with `g_shell_parse_argv`, so the path goes in
    /// single quotes for a shell.
    public static func command(executable: String) -> String {
        LinuxMarking.shellQuoted(executable) + " mark"
    }

    /// A GVariant string in its text form, as `gsettings set` reads it.
    public static func gvariantString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// `gsettings get`'s list of paths (`@as []`, `['/a/', "/b'/"]`); nil when it isn't one.
    public static func parseList(_ text: String) -> [String]? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.hasPrefix("@as") { rest = rest.dropFirst(3).drop { $0 == " " } }
        guard rest.first == "[", rest.last == "]" else { return nil }
        rest = rest.dropFirst().dropLast()
        var items: [String] = []
        func skipSpaces() { rest = rest.drop { $0 == " " } }
        skipSpaces()
        while let quote = rest.first {
            guard quote == "'" || quote == "\"" else { return nil }
            rest = rest.dropFirst()
            var item = ""
            var closed = false
            while let character = rest.first {
                rest = rest.dropFirst()
                if character == "\\" {
                    guard let escaped = rest.first else { return nil }
                    rest = rest.dropFirst()
                    item.append(escaped)
                } else if character == quote {
                    closed = true
                    break
                } else {
                    item.append(character)
                }
            }
            guard closed else { return nil }
            items.append(item)
            skipSpaces()
            if rest.first == "," {
                rest = rest.dropFirst()
                skipSpaces()
                guard !rest.isEmpty else { return nil }
            } else {
                guard rest.isEmpty else { return nil }
            }
        }
        return items
    }

    public static func formatList(_ paths: [String]) -> String {
        paths.isEmpty ? "@as []" : "[" + paths.map(gvariantString).joined(separator: ", ") + "]"
    }

    public struct Report: Equatable, Sendable {
        public var ok: Bool
        /// What to print.
        public var message: String
        /// Done, with something to know.
        public var warning: String?

        public init(ok: Bool, message: String, warning: String? = nil) {
            self.ok = ok
            self.message = message
            self.warning = warning
        }
    }

    /// The three keys first, and only then the path in the list (GNOME never sees a
    /// shortcut half made). Installed already: the keys renewed, the list left alone.
    public static func install(executable: String, runner: any GSettingsRunner) -> Report {
        let list: [String]
        switch readList(runner) {
        case .failure(let report): return report
        case .success(let read): list = read
        }
        let command = command(executable: executable)
        for (key, value) in [("name", name), ("command", command), ("binding", binding)] {
            if let failed = write(["set", itemSchema, key, gvariantString(value)], runner) { return failed }
        }
        if !list.contains(path), let failed = write(["set", listSchema, listKey, formatList(list + [path])], runner) {
            return failed
        }
        let warning = executable.contains("/.build/") ? "This aki is inside .build: the shortcut breaks if that build goes away." : nil
        return Report(ok: true, message: "Shift+Super+A now runs: \(command)", warning: warning)
    }

    /// Out of the list first, then its keys reset; the other shortcuts stay.
    public static func remove(runner: any GSettingsRunner) -> Report {
        let list: [String]
        switch readList(runner) {
        case .failure(let report): return report
        case .success(let read): list = read
        }
        if list.contains(path), let failed = write(["set", listSchema, listKey, formatList(list.filter { $0 != path })], runner) {
            return failed
        }
        for key in ["name", "command", "binding"] {
            if let failed = write(["reset", itemSchema, key], runner) { return failed }
        }
        return Report(ok: true, message: "Aki's shortcut removed.")
    }

    private enum Read { case success([String]), failure(Report) }

    private static func readList(_ runner: any GSettingsRunner) -> Read {
        switch runner.run(["get", listSchema, listKey]) {
        case .exited(0, let output):
            guard let list = parseList(String(decoding: output, as: UTF8.self)) else {
                return .failure(Report(ok: false, message: "Can't read GNOME's list of custom shortcuts: nothing was changed."))
            }
            return .success(list)
        case .timedOut: return .failure(Report(ok: false, message: "gsettings didn't answer in time."))
        case .exited, .couldNotStart: return .failure(Report(ok: false, message: "gsettings couldn't read GNOME's shortcuts."))
        }
    }

    private static func write(_ arguments: [String], _ runner: any GSettingsRunner) -> Report? {
        switch runner.run(arguments) {
        case .exited(0, _): return nil
        case .timedOut: return Report(ok: false, message: "gsettings didn't answer in time.")
        case .exited, .couldNotStart: return Report(ok: false, message: "gsettings couldn't \(arguments[0]) \(arguments[2]).")
        }
    }

    /// `gsettings` itself, by its absolute path (`Command` needs one).
    public struct ProcessRunner: GSettingsRunner {
        public let executable: String
        public init(executable: String) { self.executable = executable }
        public func run(_ arguments: [String]) -> Command.Outcome {
            Command.outcome(executable, arguments, timeout: 5)
        }
    }

    /// `gsettings` on PATH; nil without it.
    public static func gsettings(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        LinuxMarking.executable(named: "gsettings", path: path)
    }
}
